"""Remove model annotations consistently from visible captions."""
import re


def has_unclear(text):
    return isinstance(text,str) and bool(re.search(r'\[\s*unclear\b[^\]]*\]',text,re.I))


def strip_annotations(text):
    if has_unclear(text):return ''
    text=re.sub(r'\[[^\]]*\]|【[^】]*】','',text or '')
    # Strip known sound descriptions, never arbitrary parenthetical lecture content.
    sound=r"(?:(?:upbeat|soft|gentle|dramatic|background|instrumental|classical|cheerful|loud|sad|ominous|slow|fast)\s+)*(?:music|applause|laughter|noise|silence|inaudible|video playback|static|audio out|blank_audio|no_speech)(?:\s+(?:playing|continues|fades|swells))?"
    chinese=r"(?:(?:欢快|轻柔|舒缓|背景|悲伤|激昂|古典)的?)?(?:音乐|掌声|笑声|噪声|静音)(?:响起|继续|渐弱)?"
    text=re.sub(r'[（(]\s*(?:'+sound+'|'+chinese+r')\s*[)）]','',text,flags=re.I)
    return re.sub(r'\s+',' ',text).strip()


def term_source(term):
    """Glossary entries arrive either as dicts or as 'source = target (note)' strings."""
    if isinstance(term, dict):
        return str(term.get('source') or '').strip()
    return str(term).split('=')[0].strip()


def latin_words(text):
    return re.findall(r"[A-Za-z][A-Za-z'’-]{1,}", text or '')


def latin_name_gaps(english, chinese, terms):
    """Names present in the repaired English that the Chinese translation transliterated away.

    The prompt asks for Latin names to survive translation, but every provider still
    drifts into a transliteration on some runs, so the pipeline checks instead of trusting.
    """
    gaps = []
    source_text = english or ''
    translation = chinese or ''
    if not source_text or not translation:
        return gaps
    for term in terms or ():
        source = term_source(term)
        names = latin_words(source)
        if not names:
            continue
        if not any(name.lower() in source_text.lower() for name in names):
            continue
        if not any(name in translation for name in names):
            gaps.append(source)
    return gaps
