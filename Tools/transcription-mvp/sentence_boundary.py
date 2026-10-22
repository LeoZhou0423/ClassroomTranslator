"""Conservative local boundary evidence, not a full English parser."""

import re


def boundary_state(text):
    words = re.findall(r"[a-z']+", text.lower())
    if not words:
        return "incomplete"
    if text.rstrip().endswith(("...", "…", "--", "—")):
        return "incomplete"
    if words[-1] in {
        "the",
        "a",
        "an",
        "of",
        "to",
        "into",
        "with",
        "and",
        "or",
        "because",
        "if",
        "whether",
        "who",
        "which",
        "whose",
        "his",
        "their",
        "our",
        "my",
        "your",
        "in",
        "at",
        "from",
        "be",
    }:
        return "incomplete"
    tail = text.lower().rstrip(".!? ")
    nominal = re.search(
        r"\b(?:a|one|the)\s+(?:fundamental\s+)?(?:feature|aspect|property)\s+of\s+([^,;.!?]+)$",
        tail,
    )
    if nominal and not re.search(r"\b(?:is|are|was|were|has|have|can|will)\b", nominal[1]):
        return "incomplete"
    if re.search(
        r"\b(?:a theme|something|one that)\s+(?:we|you)(?:'ll| will)?\s+(?:see|hear|discuss)$", tail
    ):
        return "ambiguous"
    if re.search(r"\b(?:a little bit more|a little more|go into more)$", tail):
        return "ambiguous"
    return "complete" if re.search(r'[.!?]["\']?$', text.strip()) else "ambiguous"


def continues_previous(previous, following):
    state = boundary_state(previous)
    if state == "incomplete":
        return True
    if state == "ambiguous":
        return bool(re.match(r"(?i)\s*(?:is|are|was|were|in|of|more detail|detail)\b", following))
    return False
