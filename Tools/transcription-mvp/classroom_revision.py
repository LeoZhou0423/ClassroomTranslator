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
from concurrent.futures import ThreadPoolExecutor

from live_caption_pipeline import PIPELINE

MIMO_URL = os.getenv('LINGOCLASS_REVISION_URL', 'https://api.xiaomimimo.com/v1')
STATE_NAME = 'revision.json'


def revision_credentials():
    """The revision key is optional: without it the saved classroom keeps the live text."""
    import secrets_store
    return secrets_store.provider_key('mimo'), os.getenv('LINGOCLASS_REVISION_URL', MIMO_URL)


def read_revision(directory):
    try:
        return json.loads((directory / STATE_NAME).read_text(encoding='utf-8'))
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def ordered_rows(language):
    def position(identifier):
        parts = str(identifier).split(':')
        return tuple(int(part) if part.isdigit() else 0 for part in (parts + ['0'])[:2])
    return sorted(language.values(), key=lambda row: position(row.get('id', '0:0')))


def glossary_from(rows):
    """Recover the speaker names the live pass would have offered as terms."""
    text = ' '.join((row.get('english') or row.get('original') or '') for row in rows)
    terms = []
    for name in re.findall(r'(?i:my name is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})', text):
        name = ' '.join(name.split()[:2])
        for part in [name, *name.split()]:
            if part and not any(term == part for term in terms):
                terms.append(part)
    for name in re.findall(r'(?i:call me)\s+([A-Z][a-z]+)', text):
        if name and not any(term == name for term in terms):
            terms.append(name)
    return terms


def context_for(index, rows):
    preceding = ' '.join((rows[i].get('english') or rows[i].get('original') or '') for i in range(max(0, index - 3), index)).split()[-96:]
    following = ' '.join((rows[i].get('english') or rows[i].get('original') or '') for i in range(index + 1, min(len(rows), index + 4))).split()[:72]
    return json.dumps({'preceding': ' '.join(preceding), 'following': ' '.join(following)}, ensure_ascii=False)


AMBIGUOUS = re.compile(r'(?i)\b(respond(?:s|ed)? to|call(?:s|ed)? me|my name is|professor|refer(?:s|red)? to|address(?:es|ed)? me)\b')


def revisable(row):
    if row.get('status') != 'done':
        return False
    if row.get('annotation_suppressed') or row.get('background_candidate'):
        return False
    return bool((row.get('english') or '').strip())


def suspicious(row):
    """Only lines the fast pass is known to flatten are worth a slow second pass.

    A full pass over a six hour lecture would take hours; the automatic run repairs the
    small subset where the live output dropped a Latin name, was flagged uncertain, or
    carries the name-addressing constructions that every fast model mistranslates.
    """
    if row.get('latin_name_gaps'):
        return True
    if row.get('uncertain'):
        return True
    return bool(AMBIGUOUS.search(row.get('original') or ''))


def revise(directory, key, url, rows=None, workers=4, full=False):
    """Rewrite english/chinese in place and return how many rows changed."""
    language = json.loads((directory / 'language.json').read_text(encoding='utf-8'))
    ordered = ordered_rows(language)
    terms = glossary_from(ordered)
    targets = [index for index, row in enumerate(ordered) if revisable(row) and (full or suspicious(row))]
    changed = 0

    def work(index):
        row = ordered[index]
        result = PIPELINE.process(row['english'], context_for(index, ordered), terms, key, url,
                                  lambda english, chinese: None, timeout=(20, 120), attempts=3)
        return index, result

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for index, result in pool.map(work, targets):
            row = ordered[index]
            english = (result.get('english') or '').strip()
            chinese = (result.get('chinese') or '').strip()
            if not english or not chinese:
                continue
            row['english'] = english
            row['chinese'] = chinese
            row['revision_model'] = result.get('model') or ''
            row['revised'] = True
            changed += 1
    (directory / 'language.json').write_text(json.dumps(language, ensure_ascii=False, indent=2), encoding='utf-8')
    return changed


def start_revision(directory, wait_for_language=True, on_done=None, full=False):
    def save(value):
        temporary = directory / 'revision.tmp'
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        temporary.replace(directory / STATE_NAME)

    key, url = revision_credentials()
    if not key:
        save({'status': 'skipped', 'text': '未配置精修 Key，已保留实时译文。', 'revised_rows': 0})
        if on_done: on_done()
        return None

    def run():
        save({'status': 'pending', 'revised_rows': 0})
        try:
            deadline = time.monotonic() + (90 if wait_for_language else 0)
            while True:
                try:
                    language = json.loads((directory / 'language.json').read_text(encoding='utf-8'))
                except (OSError, ValueError):
                    language = {}
                pending = [row for row in language.values() if row.get('status') not in ('done', 'error')]
                if not pending or time.monotonic() >= deadline:
                    break
                time.sleep(.5)
            rows = json.loads((directory / 'language.json').read_text(encoding='utf-8'))
            save({'status': 'revising', 'revised_rows': 0})
            changed = revise(directory, key, url, ordered_rows(rows), full=full)
            save({'status': 'done', 'revised_rows': changed})
        except Exception as error:
            message = str(error) if isinstance(error, ValueError) else '精修失败，可稍后重试。'
            save({'status': 'error', 'text': message, 'revised_rows': 0})
        finally:
            if on_done: on_done()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread
