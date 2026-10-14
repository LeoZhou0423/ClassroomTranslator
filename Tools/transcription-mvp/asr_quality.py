"""Audio-backed revision policy. Never recover words from lecture scripts."""
import re
from difflib import SequenceMatcher


def words(text):
    return re.findall(r"[\w']+", text.lower())


def audio_supports_proposal(original, proposal, audio_text):
    """Require each proposed word plus its surrounding anchors in re-decode.

    Never prompt the acoustic decoder with the proposed replacement. A word
    occurring elsewhere in the clip does not establish positional support.
    """
    from asr_correction import valid_semantic_proposal
    if not valid_semantic_proposal(original,proposal):return False
    a,b,evidence=words(original),words(proposal),words(audio_text)
    changes=[op for op in SequenceMatcher(None,a,b,autojunk=False).get_opcodes() if op[0]!='equal']
    if not changes:return False
    for _,a0,a1,b0,b1 in changes:
        lo,hi=max(0,b0-2),min(len(b),b1+2)
        anchor=b[lo:hi]
        if len(anchor)<3:return False
        if not any(evidence[i:i+len(anchor)]==anchor for i in range(len(evidence)-len(anchor)+1)):
            return False
        old_anchor=a[lo:hi]
        if any(evidence[i:i+len(old_anchor)]==old_anchor for i in range(len(evidence)-len(old_anchor)+1)):
            return False  # Both versions were spoken; positional evidence is ambiguous.
    return True


def review_reason(previous, current):
    old, new = words(previous), words(current)
    if old and not new:
        return 'empty_final'
    if len(old) >= 6 and len(new) < len(old) * .75:
        return 'short_final'
    if re.search(r'(?i)\b(\w+)(?:\s+\1){2,}\b', current):
        return 'repetition'
    return ''


def select_audio_revision(previous, current, alternative):
    """Pick whole hypotheses, not a union that creates duplicate sentences.

    A second decode can restore an anchored truncated hypothesis. An unrelated
    result cannot overwrite it. Empty final output retains the live transcript.
    """
    base = current.strip() or previous.strip()
    candidate = alternative.strip()
    a, b = words(base), words(candidate)
    if not b:
        return base
    if not a:
        return candidate
    matches = SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()
    coverage = sum(m.size for m in matches) / len(a)
    if coverage >= .8 and len(b) > len(a):
        return candidate
    return base


def retain_missing_edges(previous, current):
    """Preserve omitted edges only when a contiguous audio-text anchor exists."""
    old, new = words(previous), words(current)
    if not new:
        return previous
    if len(old) < 6 or len(new) >= len(old):
        return current
    blocks = SequenceMatcher(None, old, new, autojunk=False).get_matching_blocks()
    anchor = max(blocks, key=lambda m: m.size)
    if anchor.size < 4 or anchor.size / len(new) < .8:
        return current
    old_spans = list(re.finditer(r"[\w']+", previous))
    prefix = previous[:old_spans[anchor.a].start()] if anchor.b == 0 and anchor.a else ''
    end = anchor.a + anchor.size
    suffix = previous[old_spans[end].start():] if anchor.b + anchor.size == len(new) and end < len(old) else ''
    return ' '.join(part.strip() for part in (prefix, current, suffix) if part.strip())
