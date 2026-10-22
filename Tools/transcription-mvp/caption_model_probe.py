"""Run the production caption prompt against several providers/models, same rows, same network.

Usage:
    python caption_model_probe.py [--provider mimo|glm] [--thinking on|off] [--rounds 1]

Every run reads the instruction straight out of live_caption_pipeline.py, replays the rows
already processed by the shipped GLM pipeline (the saved baseline), and records latency,
token usage and contract checks. Results are appended to Artifacts/caption-model-probe.json.
"""

import argparse
import ast
import json
import os
import re
import statistics
import time

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

SESSION = requests.Session()
SESSION.mount(
    "https://",
    HTTPAdapter(
        max_retries=Retry(
            total=2,
            connect=2,
            read=2,
            backoff_factor=1.5,
            status_forcelist=[429, 500, 502, 503, 504],
        )
    ),
)
PROVIDERS = {
    "mimo": {"url": "https://api.xiaomimimo.com/v1", "model": "mimo-v2.6-flash"},
    "glm": {"url": "https://open.bigmodel.cn/api/paas/v4", "model": "glm-5.3-flash"},
    "qwen": {"url": "https://maas.qianwenaiapi.com/compatible-mode/v1", "model": "qwen-plus"},
}
BASELINE = "sessions/20261013-133950-3210/language.json"
REPORT = "../../Artifacts/caption-model-probe.json"
EFFORT = "low"


def api_key(provider):
    if provider == "mimo":
        return os.getenv("MIMO_API_KEY", "")
    if provider == "qwen":
        env = os.getenv("DASHSCOPE_API_KEY", "")
        return env or secret("qwen-api-key")
    return os.getenv("BIGMODEL_API_KEY", "") or secret("bigmodel-api-key")


def secret(name):
    try:
        import keyring

        return keyring.get_password("LingoClass", name) or ""
    except Exception:
        return ""


def production_instruction():
    """Pull the three instruction literals straight out of the shipped pipeline."""
    tree = ast.parse(open("live_caption_pipeline.py", encoding="utf-8").read())
    parts = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef) or node.name != "process":
            continue
        for child in ast.walk(node):
            if isinstance(child, ast.Assign):
                target = child.targets[0]
                if (
                    isinstance(target, ast.Name)
                    and target.id == "instruction"
                    and isinstance(child.value, ast.Constant)
                ):
                    parts.append(child.value.value)
            elif isinstance(child, ast.AugAssign) and isinstance(child.target, ast.Name):
                if child.target.id == "instruction" and isinstance(child.value, ast.Constant):
                    parts.append(child.value.value)
    if len(parts) < 3:
        raise SystemExit("could not extract instruction, found %d parts" % len(parts))
    return "".join(parts)


def rows_from_baseline():
    data = json.load(open(BASELINE, encoding="utf-8"))
    ordered = sorted(data.values(), key=lambda row: row["id"])
    return [
        {
            "id": row["id"],
            "original": row["original"],
            "english": row.get("english", ""),
            "chinese": row.get("chinese", ""),
        }
        for row in ordered
    ]


def context_for(index, rows):
    """Mirror LiveLanguage.run: last 64 words of the two preceding rows, first 48 of the next two."""
    preceding = " ".join(rows[i]["original"] for i in range(max(0, index - 2), index)).split()[-64:]
    following = " ".join(
        rows[i]["original"] for i in range(index + 1, min(len(rows), index + 3))
    ).split()[:48]
    return json.dumps(
        {"preceding": " ".join(preceding), "following": " ".join(following)}, ensure_ascii=False
    )


def payload_for(provider, model, instruction, text, context, thinking, glossary=()):
    messages = [
        {"role": "system", "content": instruction},
        {
            "role": "user",
            "content": json.dumps(
                {"current": text, "reference_context": context, "glossary": list(glossary)},
                ensure_ascii=False,
            ),
        },
    ]
    payload = {
        "model": model,
        "response_format": {"type": "json_object"},
        "max_tokens": 1800,
        "stream": True,
        "stream_options": {"include_usage": True},
        "messages": messages,
    }
    if provider == "qwen":
        # The shipped qwen branch sends no response_format and no thinking.
        payload.pop("response_format", None)
        payload["enable_thinking"] = thinking
        payload["temperature"] = 0
        return payload
    if provider == "glm":
        payload["thinking"] = {"type": "enabled"} if thinking else {"type": "disabled"}
        if thinking:
            payload["reasoning_effort"] = EFFORT
        else:
            payload["temperature"] = 0
    else:
        payload["thinking"] = {"type": "enabled"} if thinking else {"type": "disabled"}
        if not thinking:
            payload["temperature"] = 0
    return payload


def call(provider, url, key, instruction, text, context, thinking, glossary=()):
    payload = payload_for(
        provider, PROVIDERS[provider]["model"], instruction, text, context, thinking, glossary
    )
    started = time.monotonic()
    first = None
    document = ""
    usage = {}
    try:
        response = SESSION.post(
            url.rstrip("/") + "/chat/completions",
            headers={"Authorization": "Bearer " + key},
            json=payload,
            stream=True,
            timeout=(20, 120),
        )
    except requests.RequestException as exc:
        return {
            "error": "network: %s" % type(exc).__name__,
            "seconds": round(time.monotonic() - started, 2),
        }
    with response:
        if not response.ok:
            return {
                "error": "HTTP %d %s" % (response.status_code, response.text[:160]),
                "seconds": round(time.monotonic() - started, 2),
            }
        for line in response.iter_lines(chunk_size=128):
            if not line.startswith(b"data:"):
                continue
            chunk = line[5:].strip()
            if chunk == b"[DONE]":
                break
            item = json.loads(chunk)
            if item.get("usage"):
                usage = item["usage"]
            choices = item.get("choices", [])
            if choices:
                piece = choices[0].get("delta", {}).get("content") or ""
                if piece and first is None:
                    first = time.monotonic()
                document += piece
    parsed = None
    error = None
    try:
        parsed = json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", document.strip()))
    except ValueError as exc:
        error = "json: %s" % exc
    return {
        "seconds": round(time.monotonic() - started, 2),
        "first_token": round(first - started, 2) if first else None,
        "usage": usage,
        "parsed": parsed,
        "error": error,
    }


def checks(text, parsed):
    if not isinstance(parsed, dict):
        return ["unparseable"]
    english = parsed.get("english")
    chinese = parsed.get("chinese")
    if not isinstance(english, str) or not isinstance(chinese, str):
        return ["missing english/chinese"]
    problems = []
    for key in ("background_probability", "teacher_probability"):
        if not isinstance(parsed.get(key), (int, float)):
            problems.append("missing " + key)
    for name in set(re.findall(r"\b(?:Shelly|Kagan)\b", text)):
        if name not in english:
            problems.append("dropped name " + name)
    if re.search(r"(?i)reference|context|glossary", chinese):
        problems.append("translated the instructions")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", default="mimo", choices=sorted(PROVIDERS))
    parser.add_argument("--thinking", default="off", choices=["on", "off"])
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument(
        "--glossary", default="", help="pipe separated terms the live pipeline would pass"
    )
    parser.add_argument("--effort", default="low", choices=["low", "high", "max"])
    arguments = parser.parse_args()
    provider, thinking = arguments.provider, arguments.thinking == "on"
    globals()["EFFORT"] = arguments.effort
    key = api_key(provider)
    if not key:
        raise SystemExit("no API key for %s" % provider)
    instruction = production_instruction()
    rows = rows_from_baseline()
    glossary = [term.strip() for term in arguments.glossary.split("|") if term.strip()]
    config = PROVIDERS[provider]
    entries = []
    for round_index in range(arguments.rounds):
        for index, row in enumerate(rows):
            result = call(
                provider,
                config["url"],
                key,
                instruction,
                row["original"],
                context_for(index, rows),
                thinking,
                glossary,
            )
            usage = result.get("usage", {})
            entries.append(
                {
                    "provider": provider,
                    "model": config["model"],
                    "thinking": thinking,
                    "round": round_index,
                    "id": row["id"],
                    "original": row["original"],
                    "glm_baseline_chinese": row["chinese"],
                    "english": (result.get("parsed") or {}).get("english"),
                    "chinese": (result.get("parsed") or {}).get("chinese"),
                    "teacher_probability": (result.get("parsed") or {}).get("teacher_probability"),
                    "background_probability": (result.get("parsed") or {}).get(
                        "background_probability"
                    ),
                    "seconds": result.get("seconds"),
                    "first_token": result.get("first_token"),
                    "usage": usage,
                    "problems": checks(row["original"], result.get("parsed")),
                    "error": result.get("error"),
                }
            )
    totals = [entry["seconds"] for entry in entries if entry.get("seconds")]
    firsts = [entry["first_token"] for entry in entries if entry.get("first_token")]
    outputs = [entry["usage"].get("completion_tokens", 0) for entry in entries]
    inputs = [entry["usage"].get("prompt_tokens", 0) for entry in entries]
    cached = [
        (entry["usage"].get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        for entry in entries
    ]
    summary = {
        "provider": provider,
        "model": config["model"],
        "thinking": thinking,
        "effort": arguments.effort,
        "glossary": glossary,
        "samples": len(entries),
        "median_seconds": round(statistics.median(totals), 2) if totals else None,
        "median_first_token": round(statistics.median(firsts), 2) if firsts else None,
        "max_seconds": round(max(totals), 2) if totals else None,
        "median_prompt_tokens": statistics.median(inputs) if inputs else None,
        "median_cached_tokens": statistics.median(cached) if cached else None,
        "median_completion_tokens": statistics.median(outputs) if outputs else None,
        "failures": sum(1 for entry in entries if entry["problems"] or entry["error"]),
    }
    report = {"instruction_chars": len(instruction), "runs": []}
    if os.path.isfile(REPORT):
        try:
            report = json.load(open(REPORT, encoding="utf-8"))
        except ValueError:
            pass
    report["runs"].append({"summary": summary, "entries": entries})
    json.dump(report, open(REPORT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False))
    for entry in entries:
        print(entry["id"], entry["seconds"], "s |", entry["chinese"])
    print("wrote", REPORT)


if __name__ == "__main__":
    main()
