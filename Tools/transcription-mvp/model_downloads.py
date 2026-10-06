"""Background, atomic model downloads with progress and explicit failures."""
import threading
from urllib.request import Request,urlopen
from app_paths import DATA_ROOT,speech_model_dir

class Downloads:
    def __init__(self):self.lock=threading.Lock();self.states={}
    def snapshot(self):
        with self.lock:return {k:dict(v) for k,v in self.states.items()}
    def start(self,name):
        if name not in ('tiny','base','small','small.en'):raise ValueError('模型名称无效')
        with self.lock:
            if self.states.get(name,{}).get('status')=='downloading':return {'ok':True}
            self.states[name]={'status':'downloading','progress':0}
        threading.Thread(target=self.run,args=(name,),daemon=True).start()
        return {'ok':True}
    def update(self,name,**fields):
        with self.lock:self.states[name].update(fields)
    def run(self,name):
        try:
            target=DATA_ROOT/'models'/f'whisper-{name}';target.mkdir(parents=True,exist_ok=True)
            base=f'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-{name}/resolve/main'
            files={f'{name}-encoder.int8.onnx':base+f'/{name}-encoder.int8.onnx',
                   f'{name}-decoder.int8.onnx':base+f'/{name}-decoder.int8.onnx',
                   f'{name}-tokens.txt':base+f'/{name}-tokens.txt',
                   'silero_vad.int8.onnx':'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx'}
            for index,(filename,url) in enumerate(files.items()):
                final=target/filename
                if final.is_file() and final.stat().st_size>1000:continue
                temporary=target/(filename+'.part')
                with urlopen(Request(url,headers={'User-Agent':'LingoClass'}),timeout=30) as response,temporary.open('wb') as output:
                    total=int(response.headers.get('Content-Length',0));copied=0
                    while True:
                        block=response.read(1024*1024)
                        if not block:break
                        output.write(block);copied+=len(block)
                        self.update(name,file=filename,progress=round((index+(copied/total if total else 0))/4*100),bytes=copied)
                    if not copied or (total and copied!=total):raise ValueError('模型下载不完整，请重试')
                temporary.replace(final)
            self.update(name,status='done',progress=100)
        except Exception as error:self.update(name,status='error',error=str(error))
DOWNLOADS=Downloads()
