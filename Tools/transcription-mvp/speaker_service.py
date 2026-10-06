"""Analyze final audio on a separate worker so captions never wait for roles."""
import json
import queue
import threading
from speaker_core import SpeakerRoleAnalyzer, TranscriptItem

class SpeakerService:
    def __init__(self):
        self.lock=threading.RLock();self.generation=0;self.rows={};self.directory=None
        self.jobs=queue.Queue();self.error=None
        self.closed=threading.Event()
        self.worker=threading.Thread(target=self.run,daemon=True)
        self.worker.start()

    def close(self):
        self.closed.set();self.jobs.put(None)
        self.worker.join()

    def reset(self,directory):
        with self.lock:
            self.generation+=1;self.rows={};self.directory=directory;self.error=None

    def submit(self,identifier,audio,text):
        self.jobs.put((self.generation,identifier,audio.copy(),text))

    def snapshot(self):
        with self.lock:return dict(self.rows)

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
                result={key:{'speaker_id':item.speaker_id,'label':names.get(item.speaker_id,'说话人'),
                             'role':analyzer.roles.get(item.speaker_id,('speaker',0))[0]} for key,item in zip(ids,items)}
                with self.lock:
                    if generation!=self.generation:continue
                    self.rows=result
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
