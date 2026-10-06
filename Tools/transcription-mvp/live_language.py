"""Revision-aware language processing, independent of the audio worker."""
import json
import os
import threading
import time
import re
import requests
from grammar_model import GRAMMAR


def repair_clause_boundaries(text):
    # A trailing temporal clause followed by a short retrospective sentence
    # may be attached to the wrong sentence by ASR punctuation. Preserve every
    # word; move only the boundary, and only for this constrained construction.
    return re.sub(r'\s+(when\s+(?:I|we|he|she|they)\s+(?:was|were)\s+[^.!?]{1,24})\.\s+(It|That|This)\s+(seemed|worked|was)\b',
        lambda m:'. '+m[1][0].upper()+m[1][1:]+', '+m[2].lower()+' '+m[3],text)


def caption_english(original):
    text=repair_clause_boundaries(original)
    text=re.sub(r'([.!?]\s+|^)([a-z])',lambda m:m[1]+m[2].upper(),text)
    text=re.sub(r',\s+(But|And)\b',lambda m:', '+m[1].lower(),text)
    # Most ASR output already has grammar. Avoid a large rewrite model on
    # every caption. Invoke it for explicit agreement or repeated-word errors.
    suspicious=re.search(r'(?i)\b(\w+)\s+\1\b|\b(?:you|we|they)\s+is\b|\bI\s+are\b|\bthis\s+sentences\b',text)
    if suspicious:
        suggestions=GRAMMAR.correct(text)
        if suggestions:text=suggestions[0]['corrected']
    return text


def group_rows(rows):
    groups=[]
    for row in rows:
        previous=groups[-1] if groups else None
        text=row['text']
        continuation=bool(re.match(r'(?i)^(but|and|because|which|that is|it seemed|for that|hours)\b',text))
        if previous and 'utterance' in row and previous.get('utterance')==row['utterance'] and len(previous['members'])<3 and len((previous['text']+' '+text).split())<=65 and (continuation or len(previous['text'].split())<6):
            previous['text']+=' '+text
            previous['members'].append(row['id'])
            previous['final']=previous['final'] and row.get('final',False)
        else:
            groups.append({**row,'members':[row['id']]})
    return groups


def boundary_score(text):
    """Conservative local heuristic, not a claim of semantic certainty."""
    words = re.findall(r"[a-z']+",text.lower())
    if not words: return 0
    score = .4 if re.search(r'[.!?][\"\']?$',text.strip()) else 0
    if len(words)>=6: score += .35
    if words[-1] in {'and','but','or','to','of','the','a','during','if','that','because'}: score -= .6
    if len(words)<4: score -= .25
    if text.rstrip().endswith(('--','—','...','…')): score -= .4
    return score


def complete_caption(text):
    words=re.findall(r"[a-z']+",text.lower())
    if not words or not re.search(r'[.!?][\"\']?$',text.strip()): return False
    if text.rstrip().endswith(('--','—','...','…')): return False
    if words[-1] in {'and','but','or','to','of','the','a','during','if','that','because'}: return False
    if ' '.join(words) in {'that is','you know','for that','during office'}: return False
    return len(words)>=3 or words in [['hello'],['hi'],['good','morning'],['thank','you']]


class LiveLanguage:
    def __init__(self):
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.pending = {}
        self.inflight = set()
        self.results = {}
        self.generation = 0
        self.cache = {}
        self.updated = {}
        self.first_seen = {}
        self.final_ids = set()
        self.flush_ids = set()
        self.usage = {'requests':0,'cache_hits':0,'prompt_tokens':0,'completion_tokens':0}
        self.directory = None
        self.key = os.getenv('DASHSCOPE_API_KEY', '')
        if not self.key:
            try:
                import keyring
                self.key = keyring.get_password('LingoClass','qwen-api-key') or ''
            except Exception: pass
        if not self.key:
            from app_paths import BUNDLE_ROOT
            private=BUNDLE_ROOT/'private-config.json'
            if private.is_file():
                self.key=json.loads(private.read_text(encoding='utf-8')).get('qwen_key','')
        self.url = os.getenv('DASHSCOPE_BASE_URL', 'https://maas.qianwenaiapi.com/compatible-mode/v1')
        self.closed=threading.Event()
        self.workers=[threading.Thread(target=self.run, daemon=True) for _ in range(3)]
        self.worker=self.workers[0]
        for worker in self.workers: worker.start()

    def close(self):
        self.closed.set();self.wake.set()
        for worker in self.workers: worker.join()

    def reset(self, directory=None):
        with self.lock:
            self.generation += 1
            self.pending.clear()
            self.updated.clear()
            self.first_seen.clear()
            self.final_ids.clear()
            self.flush_ids.clear()
            self.usage = {'requests':0,'cache_hits':0,'prompt_tokens':0,'completion_tokens':0}
            self.results.clear()
            self.directory = directory

    def submit(self, rows, flush=False):
        # Keep live English revisions independent of billable translation.
        # Submit only completed audio windows; do not translate each partial.
        rows=group_rows([row for row in rows if row.get('final',True)])
        with self.lock:
            ids = {r['id'] for r in rows}
            self.final_ids = {r['id'] for r in rows if r.get('final')}
            self.flush_ids = ids if flush else set()
            self.results = {k:v for k,v in self.results.items() if k in ids}
            self.pending = {k:v for k,v in self.pending.items() if k in ids}
            for row in rows:
                previous = self.results.get(row['id'])
                confirmed=flush or bool(row.get('confirmed',False)) or complete_caption(row['text']) or boundary_score(row['text'])>=.65
                if previous and previous['original'] == row['text']:
                    previous['source_confirmed']=confirmed
                    continue
                self.results[row['id']] = {'id':row['id'],'original':row['text'],'english':row['text'],
                    'members':row['members'],'chinese':'', 'translation_stale':False, 'status':'queued', 'source_confirmed':confirmed, 'ack':'accepted'}
                self.pending[row['id']] = (self.generation, row['text'])
                self.updated[row['id']] = time.monotonic()
                self.first_seen.setdefault(row['id'],time.monotonic())
            # Source order, rather than insertion order of revisions/retries.
            self.results = {row['id']:self.results[row['id']] for row in rows}
            self.wake.set()

    def ready(self, identifier, original):
        now = time.monotonic()
        confirmed=self.results.get(identifier,{}).get('source_confirmed',False)
        return confirmed or identifier in self.flush_ids or now-self.updated.get(identifier,now)>=10

    def take_next(self):
        # Dispatch independent ready rows; presentation retains source order.
        # One active job per row prevents duplicate paid requests on revisions.
        with self.lock:
            identifier=next((k for k in self.results if k in self.pending and k not in self.inflight and self.ready(k,self.pending[k][1])),None)
            if identifier is None: return None
            value=self.pending[identifier]
            if not self.ready(identifier,value[1]): return None
            self.results[identifier]['dispatch_reason']='confirmed' if self.results[identifier].get('source_confirmed') else 'timeout'
            self.pending.pop(identifier)
            self.inflight.add(identifier)
            return identifier,value

    def snapshot(self):
        with self.lock: return {k:dict(v) for k,v in self.results.items()}

    def publish(self, identifier, generation, original, **fields):
        with self.lock:
            current = self.results.get(identifier)
            if generation != self.generation or not current or current['original'] != original: return False
            current.update(fields)
            if self.directory:
                (self.directory/'language.json').write_text(json.dumps(self.results,ensure_ascii=False,indent=2),encoding='utf-8')
            return True

    def translate(self, text, emit):
        if not self.key: raise ValueError('请在翻译设置中配置 Qwen API Key')
        options={'source_lang':'English','target_lang':'Chinese',
            'domains':'Spoken lecture. Natural Chinese; preserve English names. Infer an omitted subject from the nearest explicit speaker, preserving first person; never invent a third person. Responding to a name means answering when called. Preserve humor naturally, including playful neuroscience metaphors. Interpret adjectives contextually. Never invent ages or facts.'}
        with self.lock:
            ordered=list(self.results.values())
        for index,row in enumerate(ordered):
            if row['english']==text:
                if index: options['domains']+=' Previous context (do not translate): '+' '.join(ordered[index-1]['english'].split()[-24:])
                break
        names=re.findall(r'(?i:my name is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})',' '.join(r['original'] for r in ordered))
        terms=[]
        all_text=' '.join(r['original'] for r in ordered)
        preferred=re.findall(r'(?i:call me)\s+([A-Z][a-z]+)',all_text)
        for name in names:
            # Case-sensitive extraction avoids consuming following prose.
            name=' '.join(name.split()[:2])
            for part in [name,*name.split()]:
                target=part
                if preferred:
                    from difflib import SequenceMatcher
                    first=part.split()[0]
                    if SequenceMatcher(None,first.lower(),preferred[0].lower()).ratio()>=.8:
                        target=preferred[0]+part[len(first):]
                if part and not any(t['source']==part for t in terms):terms.append({'source':part,'target':target})
        for name in preferred:
            if not any(t['source']==name for t in terms):terms.append({'source':name,'target':name})
        # Disambiguate the adjective only in a predicative description of a
        # person. Month names and standalone personal names are unaffected.
        if re.search(r"(?i)\b(?:I'm|I am|he is|she is|we are|they are)\s+[^.!?]{0,40}\band august\b",text):
            terms.append({'source':'august','target':'庄重威严'})
        # Name-address sense is constrained by explicit self-introduction and
        # first-person speech, rather than a global translation of "respond".
        translation_text=text
        if names and preferred:
            translation_text=re.sub(r'\bI will eventually respond to (Professor\s+[A-Z][a-z]+)',
                lambda m:'When someone addresses me as '+m[1]+', I will eventually answer',text)
        if terms:options['terms']=terms[:8]
        response = requests.post(self.url.rstrip('/')+'/chat/completions',
            headers={'Authorization':'Bearer '+self.key}, json={
                'model':'qwen-mt-flash','messages':[{'role':'user','content':translation_text}],
                'translation_options':options,'stream':True,
                'stream_options':{'include_usage':True}},
            stream=True, timeout=(10,45))
        with response:
            if not response.ok:
                try: code=response.json().get('error',{}).get('code','')
                except (ValueError, AttributeError): code=''
                if code=='insufficient_quota':
                    raise ValueError('Qwen 免费额度已用完；请在控制台充值或关闭仅使用免费额度模式')
                raise ValueError('Qwen 请求失败，HTTP '+str(response.status_code))
            output = ''
            with self.lock: self.usage['requests'] += 1
            for line in response.iter_lines(chunk_size=1):
                if not line.startswith(b'data:'): continue
                payload = line[5:].strip()
                if payload == b'[DONE]': break
                value = json.loads(payload)
                usage=value.get('usage') or {}
                with self.lock:
                    self.usage['prompt_tokens'] += usage.get('prompt_tokens',0)
                    self.usage['completion_tokens'] += usage.get('completion_tokens',0)
                if value.get('error'): raise ValueError('Qwen 返回错误')
                choices = value.get('choices',[])
                if choices:
                    output += choices[0].get('delta',{}).get('content') or ''
                    emit(output)
            if not output.strip(): raise ValueError('Qwen 返回空翻译')
            return output

    def run(self):
        while not self.closed.is_set():
            item = self.take_next()
            if not item:
                self.wake.wait(.1)
                self.wake.clear()
                continue
            identifier, (generation, original) = item
            started=time.monotonic()
            try:
                self.publish(identifier,generation,original,status='grammar',ack='processing',queue_seconds=round(started-self.updated.get(identifier,started),3))
                try: english = caption_english(original)
                except Exception as error:
                    english = original
                    self.publish(identifier,generation,original,grammar_warning=str(error))
                if not self.publish(identifier,generation,original,english=english,status='translating',grammar_seconds=round(time.monotonic()-started,3)): continue
                # Include the bounded preceding context in the cache contract.
                with self.lock:
                    keys=list(self.results)
                    index=keys.index(identifier) if identifier in keys else 0
                    context=' '.join(self.results[keys[index-1]]['english'].split()[-24:]) if index else ''
                cache_key = (self.url, english, context)
                chinese = self.cache.get(cache_key)
                if chinese is None:
                    chinese = self.translate(english,lambda s:self.publish(identifier,generation,original,chinese=s))
                    self.cache[cache_key] = chinese
                else:
                    with self.lock: self.usage['cache_hits'] += 1
                self.publish(identifier,generation,original,chinese=chinese,status='done',ack='completed',translation_stale=False,processing_seconds=round(time.monotonic()-started,3))
            except Exception as error:
                self.publish(identifier,generation,original,status='error',ack='failed',error=str(error))
            finally:
                with self.lock: self.inflight.discard(identifier)
                self.wake.set()


LANGUAGE = LiveLanguage()
import atexit
atexit.register(LANGUAGE.close)
