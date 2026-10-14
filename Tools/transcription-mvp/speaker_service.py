"""Analyze final audio on a separate worker so captions never wait for roles."""
import json
import queue
import threading
from speaker_core import SpeakerRoleAnalyzer, TranscriptItem

class SpeakerService:
    def __init__(self):
        self.lock=threading.RLock();self.generation=0;self.rows={};self.directory=None
        self.jobs=queue.Queue();self.error=None;self.persisted_context=None;self.context_roles={}
        self.closed=threading.Event()
        self.worker=threading.Thread(target=self.run,daemon=True)
        self.worker.start()

    def close(self):
        self.closed.set();self.jobs.put(None)
        self.worker.join()

    def reset(self,directory):
        with self.lock:
            self.generation+=1;self.rows={};self.directory=directory;self.error=None;self.persisted_context=None;self.context_roles={}

    def submit(self,identifier,audio,text):
        self.jobs.put((self.generation,identifier,audio.copy(),text))

    def snapshot(self,language_rows=None):
        with self.lock:
            result={key:dict(row) for key,row in self.rows.items()}
            if language_rows:
                evidence={}
                for row in language_rows.values():
                    utterance=row.get('utterance');speaker=result.get(utterance,result.get(str(utterance),{})).get('speaker_id')
                    if speaker is not None and utterance is not None:
                        evidence.setdefault(speaker,{})[utterance]=row.get('teacher_probability',0)
                for speaker,items in evidence.items():
                    recent=list(items.values())[-6:]
                    strong=[p for p in recent if isinstance(p,(int,float)) and p>=.93]
                    if len(strong)>=3:
                        self.context_roles[speaker]=sum(strong)/len(strong)
                    if len(recent)>=2 and all(isinstance(p,(int,float)) and p<=.35 for p in recent[-2:]):
                        self.context_roles.pop(speaker,None)
                for row in result.values():
                    if row['speaker_id'] in self.context_roles:
                        row.update(role='teacher',role_score=self.context_roles[row['speaker_id']])
                groups={'teacher':[],'student':[]}
                for row in result.values():
                    speaker=row['speaker_id']
                    if speaker is not None and speaker not in groups[row['role'] if row['role']=='teacher' else 'student']:
                        groups[row['role'] if row['role']=='teacher' else 'student'].append(speaker)
                for row in result.values():
                    role='teacher' if row['role']=='teacher' else 'student';ids=groups[role]
                    rank=ids.index(row['speaker_id'])+1 if row['speaker_id'] in ids else 0
                    row['label']=('老师' if role=='teacher' else '学生')+(str(rank) if len(ids)>1 and rank else '')
                if self.directory and result!=self.persisted_context:
                    temporary=self.directory/'speakers-context.tmp'
                    temporary.write_text(json.dumps(result,ensure_ascii=False),encoding='utf-8')
                    temporary.replace(self.directory/'speakers.json');self.persisted_context=result
            return result

    def run(self):
        generation=-1;analyzer=None;items=[];ids=[]
        while not self.closed.is_set():
            job=self.jobs.get()
            if job is None:
                self.jobs.task_done();break
            job_generation,identifier,audio,text=job
            try:
                if job_generation!=self.generation:continue
                if generation!=job_generation:
                    analyzer=SpeakerRoleAnalyzer();items=[];ids=[];generation=job_generation
                speaker,backfill=analyzer.assign(audio,len(items))
                ids.append(identifier);items.append(TranscriptItem(text,speaker))
                if backfill is not None:items[backfill].speaker_id=speaker
                analyzer.update_roles(items)
                names=analyzer.names({i.speaker_id for i in items if i.speaker_id is not None})
                result={key:{'speaker_id':item.speaker_id,'label':names.get(item.speaker_id,'学生'),
                             'role':analyzer.roles.get(item.speaker_id,('student',.5))[0],
                             'role_score':analyzer.roles.get(item.speaker_id,('student',.5))[1]} for key,item in zip(ids,items)}
                with self.lock:
                    if generation!=self.generation:continue
                    self.rows=result
                    self.persisted_context=None
                    if self.directory:
                        temporary=self.directory/'speakers.tmp'
                        temporary.write_text(json.dumps(result,ensure_ascii=False),encoding='utf-8')
                        temporary.replace(self.directory/'speakers.json')
            except Exception as error:
                with self.lock:self.error=str(error)
            finally:self.jobs.task_done()

SPEAKERS=SpeakerService()
import atexit
atexit.register(SPEAKERS.close)
