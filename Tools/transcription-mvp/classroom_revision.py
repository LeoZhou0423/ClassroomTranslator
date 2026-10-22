"""Re-translate a saved session with a slower, stronger model.

The live pass trades accuracy for latency: glm-5.3-flash with low reasoning effort, one
request per caption. A saved classroom can afford a slower pass, and mimo-v2.6-flash with
thinking resolves lines the fast pass flattens, such as "I will eventually respond to
Professor Kagan", which is about being addressed by that title rather than replying to a
person. Only english/chinese are replaced. The teacher and background verdicts keep the
values the live pass judged, because the revision model is demonstrably weaker at both.
"""

import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError, as_completed

from app_errors import LOGGER
from json_storage import atomic_write_json
from live_caption_pipeline import PIPELINE

MIMO_URL = os.getenv("LINGOCLASS_REVISION_URL", "https://api.xiaomimimo.com/v1")
STATE_NAME = "revision.json"
ACTIVE = {}
CANCEL_EVENTS = {}
ACTIVE_LOCK = threading.RLock()


def revision_credentials():
    """The revision key is optional: without it the saved classroom keeps the live text."""
    import secrets_store

    return secrets_store.provider_key("mimo"), os.getenv("LINGOCLASS_REVISION_URL", MIMO_URL)


def read_revision(directory):
    try:
        value = json.loads((directory / STATE_NAME).read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            return {"status": "error", "text": "精修状态文件损坏，可重新精修。"}
        with ACTIVE_LOCK:
            active = str(directory.resolve()) in ACTIVE
        if value.get("status") in ("pending", "revising", "cancelling") and not active:
            return {
                **value,
                "status": "error",
                "text": "上次精修已中断，已保存的译文仍然保留。可手动重新精修。",
            }
        return value
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def ordered_rows(language):
    def position(identifier):
        parts = str(identifier).split(":")
        return tuple(int(part) if part.isdigit() else 0 for part in (parts + ["0"])[:2])

    return sorted(language.values(), key=lambda row: position(row.get("id", "0:0")))


def glossary_from(rows):
    """Recover the speaker names the live pass would have offered as terms."""
    text = " ".join((row.get("english") or row.get("original") or "") for row in rows)
    terms = []
    for name in re.findall(r"(?i:my name is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})", text):
        name = " ".join(name.split()[:2])
        for part in [name, *name.split()]:
            if part and not any(term == part for term in terms):
                terms.append(part)
    for name in re.findall(r"(?i:call me)\s+([A-Z][a-z]+)", text):
        if name and not any(term == name for term in terms):
            terms.append(name)
    return terms


def context_for(index, rows):
    preceding = " ".join(
        (rows[i].get("english") or rows[i].get("original") or "")
        for i in range(max(0, index - 3), index)
    ).split()[-96:]
    following = " ".join(
        (rows[i].get("english") or rows[i].get("original") or "")
        for i in range(index + 1, min(len(rows), index + 4))
    ).split()[:72]
    return json.dumps(
        {"preceding": " ".join(preceding), "following": " ".join(following)}, ensure_ascii=False
    )


AMBIGUOUS = re.compile(
    r"(?i)\b(respond(?:s|ed)? to|call(?:s|ed)? me|my name is|professor|refer(?:s|red)? to|address(?:es|ed)? me)\b"
)


def revisable(row):
    if row.get("status") != "done":
        return False
    if row.get("annotation_suppressed") or row.get("background_candidate"):
        return False
    return bool((row.get("english") or "").strip())


def suspicious(row):
    """Only lines the fast pass is known to flatten are worth a slow second pass.

    A full pass over a six hour lecture would take hours; the automatic run repairs the
    small subset where the live output dropped a Latin name, was flagged uncertain, or
    carries the name-addressing constructions that every fast model mistranslates.
    """
    if row.get("latin_name_gaps"):
        return True
    if row.get("uncertain"):
        return True
    return bool(AMBIGUOUS.search(row.get("original") or ""))


def revise(directory, key, url, rows=None, workers=4, full=False, progress=None, cancel_event=None):
    """Rewrite english/chinese in place and return how many rows changed."""
    language = json.loads((directory / "language.json").read_text(encoding="utf-8"))
    ordered = ordered_rows(language)
    terms = glossary_from(ordered)
    targets = [
        index for index, row in enumerate(ordered) if revisable(row) and (full or suspicious(row))
    ]
    changed = processed = failed = 0
    total = len(targets)

    def checkpoint():
        atomic_write_json(directory / "language.json", language)

    def report():
        if progress:
            progress(processed, total, changed, failed)

    report()

    def work(index):
        if cancel_event is not None and cancel_event.is_set():
            return index, {}
        row = ordered[index]
        result = PIPELINE.process(
            row["english"],
            context_for(index, ordered),
            terms,
            key,
            url,
            lambda english, chinese: None,
            timeout=(5, 30),
            attempts=1,
        )
        return index, result

    pool = ThreadPoolExecutor(max_workers=workers)
    futures = {pool.submit(work, index): index for index in targets}
    try:
        for future in as_completed(futures, timeout=600):
            if cancel_event is not None and cancel_event.is_set():
                break
            processed += 1
            try:
                index, result = future.result()
                english = (result.get("english") or "").strip()
                chinese = (result.get("chinese") or "").strip()
                if not english or not chinese:
                    raise ValueError("empty revision")
                row = ordered[index]
                row.update(
                    english=english,
                    chinese=chinese,
                    revision_model=result.get("model") or "",
                    revised=True,
                )
                changed += 1
            except Exception as error:
                failed += 1
                LOGGER.warning("revision_row_failed kind=%s", type(error).__name__)
            if processed % 5 == 0 or processed == total:
                checkpoint()
            report()
    except TimeoutError:
        failed += total - processed
        processed = total
        report()
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
        checkpoint()
    return changed


def start_revision(directory, wait_for_language=True, on_done=None, full=False):
    identity = str(directory.resolve())
    with ACTIVE_LOCK:
        if identity in ACTIVE:
            return ACTIVE[identity]

    def save(value):
        atomic_write_json(directory / STATE_NAME, value)

    key, url = revision_credentials()
    if not key:
        save({"status": "skipped", "text": "未配置精修 Key，已保留实时译文。", "revised_rows": 0})
        if on_done:
            on_done()
        return None

    def run():
        try:
            deadline = time.monotonic() + (90 if wait_for_language else 0)
            while True:
                try:
                    language = json.loads((directory / "language.json").read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    language = {}
                pending = [
                    row for row in language.values() if row.get("status") not in ("done", "error")
                ]
                if not pending or time.monotonic() >= deadline:
                    break
                if cancel_event.wait(0.5):
                    save(
                        {
                            "status": "cancelled",
                            "text": "精修已取消，原译文已保留。",
                            "revised_rows": 0,
                        }
                    )
                    return
            rows = json.loads((directory / "language.json").read_text(encoding="utf-8"))
            save({"status": "revising", "revised_rows": 0})
            stats = {}

            def progress(processed, total, changed, failed):
                stats.update(
                    processed_rows=processed,
                    total_rows=total,
                    revised_rows=changed,
                    failed_rows=failed,
                )
                save({"status": "cancelling" if cancel_event.is_set() else "revising", **stats})

            changed = revise(
                directory,
                key,
                url,
                ordered_rows(rows),
                full=full,
                progress=progress,
                cancel_event=cancel_event,
            )
            save(
                {
                    "status": "cancelled"
                    if cancel_event.is_set()
                    else "error"
                    if stats.get("failed_rows")
                    else "done",
                    **stats,
                    "revised_rows": changed,
                    "text": "精修已取消，成功的修改已保存，其余保留原译文。"
                    if cancel_event.is_set()
                    else "部分条目精修未完成，成功的修改已保存，其余保留原译文。"
                    if stats.get("failed_rows")
                    else "",
                }
            )
        except Exception as error:
            message = str(error) if isinstance(error, ValueError) else "精修失败，可稍后重试。"
            try:
                save({"status": "error", "text": message, "revised_rows": 0})
            except OSError:
                LOGGER.error("revision_status_write_failed kind=%s", type(error).__name__)
        finally:
            with ACTIVE_LOCK:
                ACTIVE.pop(identity, None)
                CANCEL_EVENTS.pop(identity, None)
            if on_done and not cancel_event.is_set():
                on_done()

    thread = threading.Thread(target=run, daemon=True)
    cancel_event = threading.Event()
    with ACTIVE_LOCK:
        if identity in ACTIVE:
            return ACTIVE[identity]
        ACTIVE[identity] = thread
        CANCEL_EVENTS[identity] = cancel_event
        try:
            save({"status": "pending", "revised_rows": 0})
            thread.start()
        except Exception:
            ACTIVE.pop(identity, None)
            CANCEL_EVENTS.pop(identity, None)
            raise
    return thread


def cancel_revision(directory):
    """Cancel queued work; a current network request may take up to its timeout."""
    identity = str(directory.resolve())
    with ACTIVE_LOCK:
        event = CANCEL_EVENTS.get(identity)
        if event is None:
            return False
        event.set()
        state = read_revision(directory) or {}
        atomic_write_json(
            directory / STATE_NAME,
            {
                **state,
                "status": "cancelling",
                "text": "正在取消，正在进行的请求结束后停止，不再提交新条目。",
            },
        )
    return True
