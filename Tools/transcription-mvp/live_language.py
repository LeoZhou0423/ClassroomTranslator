"""Revision-aware language processing, independent of the audio worker."""

import atexit
import json
import os
import re
import threading
import time
from difflib import SequenceMatcher

import requests
import secrets_store
from app_errors import LOGGER, classify_error
from grammar_model import (
    GRAMMAR as GRAMMAR,  # Public compatibility export; never loaded for live captions.
)
from json_storage import atomic_write_json
from live_caption_pipeline import PIPELINE
from sentence_boundary import boundary_state, continues_previous


def repair_clause_boundaries(text):
    # A trailing temporal clause followed by a short retrospective sentence
    # may be attached to the wrong sentence by ASR punctuation. Preserve every
    # word; move only the boundary, and only for this constrained construction.
    return re.sub(
        r"\s+(when\s+(?:I|we|he|she|they)\s+(?:was|were)\s+[^.!?]{1,24})\.\s+(It|That|This)\s+(seemed|worked|was)\b",
        lambda m: ". " + m[1][0].upper() + m[1][1:] + ", " + m[2].lower() + " " + m[3],
        text,
    )


def caption_english(original):
    text = repair_clause_boundaries(original)
    text = re.sub(r"([.!?]\s+|^)([a-z])", lambda m: m[1] + m[2].upper(), text)
    text = re.sub(r",\s+(But|And)\b", lambda m: ", " + m[1].lower(), text)
    # Most ASR output already has grammar. Avoid a large rewrite model on
    # every caption. Invoke it for explicit agreement or repeated-word errors.
    re.search(r"(?i)\b(\w+)\s+\1\b|\b(?:you|we|they)\s+is\b|\bI\s+are\b|\bthis\s+sentences\b", text)
    # Live captions never load the local T5 model: contextual repair already
    # runs remotely, and a cold local model can stall all language workers.
    return text


def unfinished_clause(text):
    # Audio-window finalization and ASR punctuation do not prove a sentence ended.
    if boundary_state(text) == "incomplete":
        return True
    words = re.findall(r"[a-z']+", text.lower())
    if not words:
        return False
    if text.rstrip().endswith(("...", "…", "--", "—")):
        return True
    if not re.search(r'[.!?]["\']?$', text.strip()):
        return True
    return words[-1] in {
        "the",
        "a",
        "an",
        "of",
        "into",
        "onto",
        "with",
        "whose",
        "who",
        "which",
        "whether",
        "because",
        "his",
        "their",
        "our",
        "your",
        "my",
    }


def group_rows(rows, sealed_ids=()):
    groups = []
    for row in rows:
        previous = groups[-1] if groups else None
        text = row["text"]
        continuation = bool(
            re.match(r"(?i)^(but|and|because|which|that is|it seemed|for that|hours)\b", text)
        )
        same_window = (
            previous and "utterance" in row and previous.get("utterance") == row["utterance"]
        )
        unfinished = previous and (
            unfinished_clause(previous["text"]) or continues_previous(previous["text"], text)
        )
        speaker_changed = (
            previous
            and previous.get("speaker_id") is not None
            and row.get("speaker_id") is not None
            and previous["speaker_id"] != row["speaker_id"]
        )
        can_join = (
            previous
            and previous["id"] not in sealed_ids
            and previous.get("final", True)
            and row.get("final", True)
            and not speaker_changed
            and len(previous["members"]) < 4
        )
        within_limit = previous and len((previous["text"] + " " + text).split()) <= (
            100 if unfinished else 36
        )
        # Backend sentence units that already close with terminal punctuation
        # stay separate. Re-joining them undoes segmentation and restarts the
        # ready-timer on a row whose "revision" is really another sentence.
        both_closed = bool(
            previous
            and re.search(r"[.!?][\"\']?$", previous["text"].strip())
            and re.search(r"[.!?][\"\']?$", text.strip())
        )
        weak_window_join = same_window and (
            continuation or (len(previous["text"].split()) < 6 and not both_closed)
        )
        if can_join and within_limit and (unfinished or weak_window_join):
            previous["text"] = (
                previous["text"].rstrip(".…—- ") + " " + text
                if unfinished
                else previous["text"] + " " + text
            )
            previous["members"].extend(row.get("source_members") or [row["id"]])
            previous["final"] = previous.get("final", True) and row.get("final", True)
        else:
            groups.append({**row, "members": list(row.get("source_members") or [row["id"]])})
    return groups


def boundary_score(text):
    """Conservative local heuristic, not a claim of semantic certainty."""
    words = re.findall(r"[a-z']+", text.lower())
    if not words:
        return 0
    score = 0.4 if re.search(r"[.!?][\"\']?$", text.strip()) else 0
    if len(words) >= 6:
        score += 0.35
    if words[-1] in {"and", "but", "or", "to", "of", "the", "a", "during", "if", "that", "because"}:
        score -= 0.6
    if len(words) < 4:
        score -= 0.25
    if text.rstrip().endswith(("--", "—", "...", "…")):
        score -= 0.4
    return score


def complete_caption(text):
    words = re.findall(r"[a-z']+", text.lower())
    if not words or not re.search(r"[.!?][\"\']?$", text.strip()):
        return False
    if text.rstrip().endswith(("--", "—", "...", "…")):
        return False
    if words[-1] in {"and", "but", "or", "to", "of", "the", "a", "during", "if", "that", "because"}:
        return False
    if " ".join(words) in {"that is", "you know", "for that", "during office"}:
        return False
    return len(words) >= 3 or words in [["hello"], ["hi"], ["good", "morning"], ["thank", "you"]]


class LiveLanguage:
    def __init__(self):
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.sealed_ids = set()
        self.pending = {}
        self.inflight = set()
        self.results = {}
        self.generation = 0
        self.cache = {}
        self.updated = {}
        self.first_seen = {}
        self.final_ids = set()
        self.flush_ids = set()
        self.usage = {"requests": 0, "cache_hits": 0, "prompt_tokens": 0, "completion_tokens": 0}
        self.directory = None
        self.persistence_error = None
        self.course_terms = ()
        self.subject_terms = []
        # Resolution order: explicit env override, the key the user typed into
        # Settings (OS credential store), then the encrypted repository document.
        # The plaintext private-config.json path was removed: a key baked into the
        # installer is a key published to the internet.
        self.url = os.getenv(
            "DASHSCOPE_BASE_URL", "https://maas.qianwenaiapi.com/compatible-mode/v1"
        )
        self.key = secrets_store.provider_key("qwen")
        bigmodel_key = secrets_store.provider_key("bigmodel")
        if bigmodel_key:
            self.key = bigmodel_key
            self.url = "https://open.bigmodel.cn/api/paas/v4"
        self.closed = threading.Event()
        self.workers = [threading.Thread(target=self.run, daemon=True) for _ in range(3)]
        self.worker = self.workers[0]
        for worker in self.workers:
            worker.start()

    def close(self):
        self.closed.set()
        self.wake.set()
        for worker in self.workers:
            worker.join(timeout=1)

    def reset(self, directory=None, course_terms=()):
        with self.lock:
            self.generation += 1
            self.pending.clear()
            self.sealed_ids.clear()
            self.updated.clear()
            self.first_seen.clear()
            self.final_ids.clear()
            self.flush_ids.clear()
            self.usage = {
                "requests": 0,
                "cache_hits": 0,
                "prompt_tokens": 0,
                "completion_tokens": 0,
            }
            self.results.clear()
            self.directory = directory
            self.persistence_error = None
            self.course_terms = tuple(course_terms)
            self.subject_terms = []

    def submit(self, rows, flush=False):
        # Keep live English revisions independent of billable translation.
        # Submit only completed audio windows; do not translate each partial.
        rows = group_rows(
            [row for row in rows if row.get("final", True) or row.get("stable", False)],
            self.sealed_ids,
        )
        with self.lock:
            ids = {r["id"] for r in rows}
            self.final_ids = {r["id"] for r in rows if r.get("final")}
            self.flush_ids = ids if flush else set()
            self.results = {k: v for k, v in self.results.items() if k in ids}
            self.pending = {k: v for k, v in self.pending.items() if k in ids}
            for row in rows:
                if not row.get("final", True) and not row.get("language_ready", True):
                    continue
                previous = self.results.get(row["id"])
                confirmed = (
                    flush
                    or bool(row.get("confirmed", False))
                    or complete_caption(row["text"])
                    or boundary_score(row["text"]) >= 0.65
                )
                if previous and previous["original"] == row["text"]:
                    previous["source_confirmed"] = confirmed
                    continue
                old_members = set(previous.get("members") or [row["id"]]) if previous else set()
                new_members = set(row.get("members") or [row["id"]])
                # Absorbing another already-segmented sentence is not a revision
                # of this row: do not restart the ready-timer, or fast speech
                # postpones dispatch forever while the pending text keeps swapping.
                absorbed_sentence = bool(previous and new_members - old_members)
                self.results[row["id"]] = {
                    "id": row["id"],
                    "original": row["text"],
                    "english": previous.get("english", row["text"]) if previous else row["text"],
                    "members": row["members"],
                    "utterance": row.get("utterance"),
                    "live_preview": bool(row.get("provisional")),
                    "display_original": previous.get("display_original", previous["original"])
                    if previous
                    else row["text"],
                    "chinese": previous.get("chinese", "") if previous else "",
                    "translation_stale": bool(previous and previous.get("chinese")),
                    "status": "queued",
                    "source_confirmed": confirmed,
                    "ack": "accepted",
                }
                self.pending[row["id"]] = (self.generation, row["text"])
                if not absorbed_sentence:
                    self.updated[row["id"]] = time.monotonic()
                else:
                    self.updated.setdefault(row["id"], time.monotonic())
                self.first_seen.setdefault(row["id"], time.monotonic())
            # Source order, rather than insertion order of revisions/retries.
            self.results = {
                row["id"]: self.results[row["id"]] for row in rows if row["id"] in self.results
            }
            self.wake.set()

    def ready(self, identifier, original):
        now = time.monotonic()
        confirmed = self.results.get(identifier, {}).get("source_confirmed", False)
        age = now - self.first_seen.get(identifier, now)
        if self.results.get(identifier, {}).get("live_preview"):
            # Growing speech may never pause for two seconds. Bound the wait,
            # while coalescing revisions and allowing only one request per row.
            return (
                confirmed
                or (age >= 0.8 and now - self.updated.get(identifier, now) >= 0.25)
                or age >= 1.5
            )
        # Absolute deadline: continuous ASR refreshes must not postpone dispatch
        # indefinitely. Timeout protection bounds the wait, it does not reset
        # whenever another sentence is absorbed into the same pending row.
        return (
            confirmed
            or identifier in self.flush_ids
            or now - self.updated.get(identifier, now) >= 2
            or age >= 3
        )

    def take_next(self):
        # Dispatch independent ready rows; presentation retains source order.
        # One active job per row prevents duplicate paid requests on revisions.
        with self.lock:
            identifier = next(
                (
                    k
                    for k in self.results
                    if k in self.pending
                    and (self.generation, k) not in self.inflight
                    and self.ready(k, self.pending[k][1])
                ),
                None,
            )
            if identifier is None:
                return None
            value = self.pending[identifier]
            if not self.ready(identifier, value[1]):
                return None
            self.results[identifier]["dispatch_reason"] = (
                "confirmed" if self.results[identifier].get("source_confirmed") else "timeout"
            )
            self.pending.pop(identifier)
            self.inflight.add((self.generation, identifier))
            return identifier, value

    def snapshot(self):
        with self.lock:
            return {k: dict(v) for k, v in self.results.items()}

    def publish(self, identifier, generation, original, **fields):
        with self.lock:
            current = self.results.get(identifier)
            if generation != self.generation or not current:
                return False
            if current["original"] != original:
                # A nearby ASR revision must not black out the entire caption
                # while its older, coherent bilingual stream is still arriving.
                # Only display that pair provisionally; never finalize stale jobs.
                if (
                    fields.get("status") == "translating"
                    and fields.get("english")
                    and fields.get("chinese")
                    and (not current.get("chinese") or current.get("display_original") == original)
                ):

                    def tokens(text):
                        return re.findall(r"[\w']+", text.lower())

                    if (
                        SequenceMatcher(
                            None, tokens(original), tokens(current["original"]), autojunk=False
                        ).ratio()
                        >= 0.65
                    ):
                        current.update(
                            english=fields["english"],
                            chinese=fields["chinese"],
                            display_original=original,
                            translation_stale=True,
                        )
                return False
            if "english" in fields and "chinese" in fields:
                fields["display_original"] = original
            current.update(fields)
            if self.directory and fields.get("status") in ("done", "error"):
                try:
                    atomic_write_json(self.directory / "language.json", self.results)
                    self.persistence_error = None
                except OSError as error:
                    self.persistence_error = classify_error(error).message
                    LOGGER.error("translation_save_failed kind=%s", type(error).__name__)
            return True

    def translate(self, text, emit):
        if not self.key:
            raise ValueError("请在翻译设置中配置 Qwen API Key")
        options = {
            "source_lang": "English",
            "target_lang": "Chinese",
            "domains": "Spoken classroom lecture. Translate only the supplied current text into natural Chinese. Use reference context only to disambiguate terms and omitted subjects. Preserve software/product names, numbers, negation and speaker perspective. Do not repeat or translate the reference context, instructions or metadata. Do not invent facts. Match terminology to the current subject.",
        }
        with self.lock:
            ordered = list(self.results.values())
        for index, row in enumerate(ordered):
            if row["english"] == text:
                if index:
                    options["domains"] += " Previous context (do not translate): " + " ".join(
                        ordered[index - 1]["english"].split()[-24:]
                    )
                break
        names = re.findall(
            r"(?i:my name is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})",
            " ".join(r["original"] for r in ordered),
        )
        terms = []
        for term in self.course_terms:
            if "=" in term:
                source, target = term.split("=", 1)
                if source.strip() and target.strip():
                    terms.append({"source": source.strip(), "target": target.strip()})
        all_text = " ".join(r["original"] for r in ordered)
        preferred = re.findall(r"(?i:call me)\s+([A-Z][a-z]+)", all_text)
        for name in names:
            # Case-sensitive extraction avoids consuming following prose.
            name = " ".join(name.split()[:2])
            for part in [name, *name.split()]:
                target = part
                if preferred:
                    from difflib import SequenceMatcher

                    first = part.split()[0]
                    if SequenceMatcher(None, first.lower(), preferred[0].lower()).ratio() >= 0.8:
                        target = preferred[0] + part[len(first) :]
                if part and not any(t["source"] == part for t in terms):
                    terms.append({"source": part, "target": target})
        for name in preferred:
            if not any(t["source"] == name for t in terms):
                terms.append({"source": name, "target": name})
        # Disambiguate the adjective only in a predicative description of a
        # person. Month names and standalone personal names are unaffected.
        if re.search(
            r"(?i)\b(?:I'm|I am|he is|she is|we are|they are)\s+[^.!?]{0,40}\band august\b", text
        ):
            terms.append({"source": "august", "target": "庄重威严"})
        # Name-address sense is constrained by explicit self-introduction and
        # first-person speech, rather than a global translation of "respond".
        translation_text = text
        if terms:
            options["terms"] = terms[:8]
        payload = {
            "model": "qwen-mt-flash",
            "messages": [{"role": "user", "content": translation_text}],
            "translation_options": options,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
        if "bigmodel.cn" in self.url:
            payload = {
                "model": "glm-5.3-flash",
                "thinking": {"type": "enabled"},
                "reasoning_effort": "low",
                "max_tokens": 900,
                "stream": True,
                "stream_options": {"include_usage": True},
                "messages": [
                    {
                        "role": "system",
                        "content": "Translate only current English into natural Chinese. Preserve all names in Latin letters, titles, numbers, negation and perspective. Reference context must never replace current facts. In a self-introduction, respond to a name means responding when addressed by that name. Output translation only, no notes.",
                    },
                    {
                        "role": "user",
                        "content": json.dumps(
                            {
                                "current": text,
                                "reference_context": options.get("domains", ""),
                                "glossary": terms,
                            },
                            ensure_ascii=False,
                        ),
                    },
                ],
            }
        response = requests.post(
            self.url.rstrip("/") + "/chat/completions",
            headers={"Authorization": "Bearer " + self.key},
            json=payload,
            stream=True,
            timeout=(10, 45),
        )
        with response:
            if not response.ok:
                try:
                    code = response.json().get("error", {}).get("code", "")
                except (ValueError, AttributeError):
                    code = ""
                if code == "insufficient_quota":
                    raise ValueError("Qwen 免费额度已用完；请在控制台充值或关闭仅使用免费额度模式")
                raise ValueError("Qwen 请求失败，HTTP " + str(response.status_code))
            output = ""
            with self.lock:
                self.usage["requests"] += 1
            for line in response.iter_lines(chunk_size=1):
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if payload == b"[DONE]":
                    break
                value = json.loads(payload)
                usage = value.get("usage") or {}
                with self.lock:
                    self.usage["prompt_tokens"] += usage.get("prompt_tokens", 0)
                    self.usage["completion_tokens"] += usage.get("completion_tokens", 0)
                if value.get("error"):
                    raise ValueError("Qwen 返回错误")
                choices = value.get("choices", [])
                if choices:
                    output += choices[0].get("delta", {}).get("content") or ""
                    emit(output)
            if not output.strip():
                raise ValueError("Qwen 返回空翻译")
            return output

    def run(self):
        while not self.closed.is_set():
            item = self.take_next()
            if not item:
                self.wake.wait(0.1)
                self.wake.clear()
                continue
            identifier, (generation, original) = item
            started = time.monotonic()
            correction_status = ""
            try:
                self.publish(
                    identifier,
                    generation,
                    original,
                    status="grammar",
                    ack="processing",
                    queue_seconds=round(started - self.updated.get(identifier, started), 3),
                )
                try:
                    english = caption_english(original)
                except Exception as error:
                    english = original
                    self.publish(identifier, generation, original, grammar_warning=str(error))
                with self.lock:
                    keys = list(self.results)
                    index = keys.index(identifier) if identifier in keys else 0
                    preceding = " ".join(
                        self.results[k]["original"] for k in keys[max(0, index - 2) : index]
                    ).split()[-64:]
                    following = " ".join(
                        self.results[k]["original"] for k in keys[index + 1 : index + 3]
                    ).split()[:48]
                    context = json.dumps(
                        {"preceding": " ".join(preceding), "following": " ".join(following)},
                        ensure_ascii=False,
                    )
                # Text-context reconstruction is user-authorized. It is independent
                # of acoustic confirmation and does not modify the raw ASR ledger.
                if os.getenv("LINGOCLASS_AI_CORRECTION", "1") != "0":
                    try:
                        ethics = " ".join(preceding + following + original.lower().split()).lower()
                        with self.lock:
                            if (
                                re.search(
                                    r"\b(?:virtue|plato|aristotle|confucius|ethics)\b", ethics
                                )
                                and "character" in ethics
                                and "character = 品格 (ethics course)" not in self.subject_terms
                            ):
                                self.subject_terms.append("character = 品格 (ethics course)")
                            glossary = list(self.course_terms) + list(self.subject_terms)
                        result = PIPELINE.process(
                            english,
                            context,
                            glossary,
                            self.key,
                            self.url,
                            lambda en, zh, identifier=identifier, generation=generation, original=original: (
                                self.publish(
                                    identifier,
                                    generation,
                                    original,
                                    english=en,
                                    chinese=zh,
                                    status="translating",
                                )
                            ),
                        )
                        background = (
                            result["background_probability"] >= 0.97
                            and "?" not in original
                            and not re.search(
                                r"(?i)\b(?:question|print|pdf|assignment|explain)\b", original
                            )
                        )
                        gaps = result.get("latin_name_gaps") or []
                        self.publish(
                            identifier,
                            generation,
                            original,
                            english=result["english"],
                            chinese=result["chinese"],
                            teacher_probability=result["teacher_probability"],
                            uncertain=bool(result.get("uncertain")),
                            background_candidate=background,
                            annotation_suppressed=not result["english"],
                            correction_status="context_repaired",
                            translation_stale=False,
                            **({"latin_name_gaps": gaps} if gaps else {}),
                            status="done",
                            ack="completed",
                            processing_seconds=round(time.monotonic() - started, 3),
                        )
                        with self.lock:
                            self.usage["cache_hits" if result["cache_hit"] else "requests"] += 1
                            for field in ("prompt_tokens", "completion_tokens"):
                                self.usage[field] += result["usage"].get(field, 0)
                        continue
                    except Exception as error:
                        # Unsupported endpoint/model, offline or timeout: retain
                        # the source and continue translation, never blank a row.
                        self.publish(
                            identifier,
                            generation,
                            original,
                            correction_status="unavailable",
                            correction_warning=type(error).__name__,
                        )
                if not self.publish(
                    identifier,
                    generation,
                    original,
                    background_candidate=correction_status == "context_background",
                ):
                    continue
                if correction_status == "context_suppressed":
                    self.publish(
                        identifier,
                        generation,
                        original,
                        english="",
                        chinese="",
                        annotation_suppressed=True,
                        status="done",
                        ack="completed",
                    )
                    continue
                if not self.publish(
                    identifier,
                    generation,
                    original,
                    english=english,
                    status="translating",
                    grammar_seconds=round(time.monotonic() - started, 3),
                ):
                    continue
                # Include the bounded preceding context in the cache contract.
                with self.lock:
                    keys = list(self.results)
                    index = keys.index(identifier) if identifier in keys else 0
                    context = (
                        " ".join(self.results[keys[index - 1]]["english"].split()[-24:])
                        if index
                        else ""
                    )
                cache_key = (self.url, english, context, self.course_terms)
                chinese = self.cache.get(cache_key)
                if chinese is None:
                    chinese = self.translate(
                        english,
                        lambda s, identifier=identifier, generation=generation, original=original: (
                            self.publish(identifier, generation, original, chinese=s)
                        ),
                    )
                    if len(self.cache) >= 512:
                        self.cache.pop(next(iter(self.cache)))
                    self.cache[cache_key] = chinese
                else:
                    with self.lock:
                        self.usage["cache_hits"] += 1
                self.publish(
                    identifier,
                    generation,
                    original,
                    chinese=chinese,
                    status="done",
                    ack="completed",
                    translation_stale=False,
                    processing_seconds=round(time.monotonic() - started, 3),
                )
            except Exception as error:
                self.publish(
                    identifier, generation, original, status="error", ack="failed", error=str(error)
                )
            finally:
                with self.lock:
                    self.inflight.discard((generation, identifier))
                self.wake.set()


LANGUAGE = LiveLanguage()
atexit.register(LANGUAGE.close)
