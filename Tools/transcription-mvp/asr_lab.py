from __future__ import annotations
import argparse
import collections
import io
import json
import mimetypes
import math
import queue
import secrets
import threading
import time
import wave
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
import numpy as np
import sherpa_onnx
import sounddevice as sd
from scipy.signal import resample_poly
from asr_core import TranscriptLedger, accepted_english, reconcile_boundary, AudioWindowOwners
from live_language import LANGUAGE
from desktop_store import DesktopStore
from app_paths import DATA_ROOT, MODEL_ROOT, WEB_ROOT, ICON_PATH, speech_model_dir
from model_downloads import DOWNLOADS
from speaker_service import SPEAKERS
from noise_reduction import NoiseReducer

ROOT = Path(__file__).resolve().parent
RATE = 16000
BUILD_VERSION = "20261005-caption-realtime-4"
STORE = DesktopStore(DATA_ROOT)


def read_wav(data):
    with wave.open(io.BytesIO(data), "rb") as source:
        channels, width, rate = source.getnchannels(), source.getsampwidth(), source.getframerate()
        if width not in (2, 4): raise ValueError("请使用 PCM 16-bit 或 PCM 32-bit WAV 文件")
        raw = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2" if width == 2 else "<i4")
        audio = raw.reshape(-1, channels).astype(np.float32).mean(axis=1) / (32768.0 if width == 2 else 2147483648.0)
    if rate != RATE:
        divisor = math.gcd(rate, RATE)
        audio = resample_poly(audio, RATE//divisor, rate//divisor).astype(np.float32)
    if not len(audio): raise ValueError("音频文件为空")
    return audio


def models():
    result = []
    for name in ("tiny", "base", "small", "small.en"):
        directory = speech_model_dir(name)
        files = [f"{name}-encoder.int8.onnx", f"{name}-decoder.int8.onnx", f"{name}-tokens.txt", "silero_vad.int8.onnx"]
        result.append({"name":name, "ready":all((directory / f).is_file() for f in files)})
    return result


class Lab:
    def __init__(self):
        self.lock = threading.RLock()
        self.condition = threading.Condition()
        self.phase = "idle"
        self.failure = None
        self.stop_event = threading.Event()
        self.pause_event = threading.Event()
        self.capture_done = threading.Event()
        self.vad_done = False
        self.audio = queue.Queue(maxsize=300)
        self.finals = collections.deque()
        self.partials = {}
        self.ledger = TranscriptLedger()
        self.logs = collections.deque(maxlen=500)
        self.session_dir = None
        self.config = {}
        self.metrics = {"rms":0, "speech":False, "captured_seconds":0, "decode_seconds":0, "rtf":0, "dropped_blocks":0, "in_flight":False}
        self.worker = None
        self.raw = None
        self.raw_sink = None
        self.decoder_cache = {}
        self.decoder_lock = threading.Lock()

    def decoder(self, name, threads):
        with self.decoder_lock:
            key=(name,threads)
            if key not in self.decoder_cache:
                directory=speech_model_dir(name)
                self.decoder_cache[key]=sherpa_onnx.OfflineRecognizer.from_whisper(
                    encoder=str(directory/f'{name}-encoder.int8.onnx'),decoder=str(directory/f'{name}-decoder.int8.onnx'),
                    tokens=str(directory/f'{name}-tokens.txt'),language='en',task='transcribe',num_threads=threads)
            return self.decoder_cache[key]

    def log(self, event, **fields):
        entry = {"time":datetime.now().isoformat(timespec="milliseconds"), "event":event, **fields}
        with self.lock:
            if event in {"capture_error","vad_error","worker_error"}: self.failure = fields.get("message",event)
            self.logs.append(entry)
            if self.session_dir:
                with (self.session_dir / "events.jsonl").open("a", encoding="utf-8") as out: out.write(json.dumps(entry, ensure_ascii=False)+"\n")

    def state(self):
        with self.lock:
            rows, live = self.ledger.snapshot()
            result = {"version":BUILD_VERSION,"phase":self.phase, "error":self.failure, "rows":rows, "live":live, "transcript":self.ledger.text(), "logs":list(self.logs)[-80:], "metrics":dict(self.metrics),
                      "config":self.config, "session_dir":str(self.session_dir or ""), "language_rows":LANGUAGE.snapshot(),
                      "translation_usage":dict(LANGUAGE.usage),'speaker_rows':SPEAKERS.snapshot(),'speaker_error':SPEAKERS.error}
        with self.condition: result["metrics"]["pending_finals"] = len(self.finals)
        return result

    def start(self, config, samples=None):
        with self.lock:
            if self.phase in ("loading", "recording", "paused", "stopping"): raise ValueError("上次录音仍在收尾，请等待完成")
            if self.worker and self.worker.is_alive(): raise ValueError("解码线程仍在收尾")
            name = config.get("model", "small")
            if name not in {m["name"] for m in models() if m["ready"]}: raise ValueError("模型尚未下载，请先运行 run.ps1 -Model "+name)
            threshold = float(config.get("vad_threshold", .5))
            silence = float(config.get("silence", .7))
            interval = float(config.get("partial_interval", 1.5))
            rms = float(config.get("minimum_rms", .004))
            threads = int(config.get("threads", 4))
            if not (.1 <= threshold <= .9 and .3 <= silence <= 2 and 1 <= interval <= 5 and 0 <= rms <= .1 and 1 <= threads <= 8): raise ValueError("参数超出允许范围")
            device = config.get("device")
            self.config = {"model":name,"language":"en","backend":"sherpa-onnx CPU INT8", "vad_threshold":threshold,"silence":silence,
                           "partial_interval":interval,"minimum_rms":rms,"threads":threads,"device":device,"source":"wav" if samples is not None else "microphone",
                           "replay_realtime":bool(config.get("replay_realtime",True))}
            self.config.update({key:config[key] for key in ('course_id','course_name') if key in config})
            self.config['noise_reduction']=bool(config.get('noise_reduction',True))
            self.session_dir = DATA_ROOT / "sessions" / (datetime.now().strftime("%Y%m%d-%H%M%S")+"-"+secrets.token_hex(2))
            self.session_dir.mkdir(parents=True)
            SPEAKERS.reset(self.session_dir)
            (self.session_dir / "config.json").write_text(json.dumps(self.config,ensure_ascii=False,indent=2),encoding="utf-8")
            self.ledger = TranscriptLedger()
            LANGUAGE.reset(self.session_dir)
            self.failure = None
            self.logs.clear()
            self.audio = queue.Queue(maxsize=300)
            self.finals.clear(); self.partials.clear()
            self.vad_done = False
            self.stop_event.clear(); self.capture_done.clear()
            self.pause_event.clear()
            self.metrics = {"rms":0,"speech":False,"captured_seconds":0,"decode_seconds":0,"rtf":0,"dropped_blocks":0,"in_flight":False}
            self.phase = "loading"
            self.worker = threading.Thread(target=self._run,args=(samples,),daemon=True)
            self.worker.start()

    def stop(self):
        with self.lock:
            if self.phase in ("loading", "recording", "paused"):
                self.phase = "stopping"
                self.stop_event.set()
                self.log("stop_requested", action="drain captured audio and all final jobs")

    def pause(self):
        with self.lock:
            if self.phase != 'recording': raise ValueError('当前不在录音中')
            self.pause_event.set()
            # A marked synthetic gap closes the current VAD window. It is saved
            # in the audio timeline but excluded from captured speaking time.
            try: self.audio.put_nowait({'pause':np.zeros(RATE,dtype=np.float32)})
            except queue.Full:
                self.pause_event.clear()
                raise ValueError('音频正在收尾，请稍后暂停')
            self.phase='paused'
            self.log('recording_paused',synthetic_gap_seconds=1)

    def resume(self):
        with self.lock:
            if self.phase != 'paused': raise ValueError('当前录音未暂停')
            self.phase='recording'; self.pause_event.clear()
            self.log('recording_resumed')

    def _capture(self, samples):
        try:
            if samples is not None:
                start = time.perf_counter()
                for offset in range(0,len(samples),512):
                    waiting=time.perf_counter()
                    while self.pause_event.is_set() and not self.stop_event.wait(.05): pass
                    start += time.perf_counter()-waiting
                    if self.stop_event.is_set(): break
                    block = samples[offset:offset+512].copy()
                    while not self.stop_event.is_set():
                        try: self.audio.put(block,timeout=.1); break
                        except queue.Full: continue
                    if self.stop_event.is_set(): break
                    if self.config.get("replay_realtime",True):
                        self.stop_event.wait(max(0,(offset+512)/RATE-(time.perf_counter()-start)))
            else:
                device = self.config["device"]
                input_rate = RATE
                try: sd.check_input_settings(device=device,channels=1,samplerate=RATE)
                except sd.PortAudioError: input_rate = int(sd.query_devices(device,"input")["default_samplerate"])
                self.log("input_format", sample_rate=input_rate, channels=1)
                def callback(data, frames, timing, status):
                    if self.pause_event.is_set(): return
                    if status: self.log("audio_status", status=str(status))
                    try: self.audio.put_nowait((data[:,0].copy(),input_rate))
                    except queue.Full:
                        with self.lock: self.metrics["dropped_blocks"] += 1
                        self.log("audio_overflow", warning="captured audio was dropped; this session is not lossless")
                with sd.InputStream(device=device,channels=1,samplerate=input_rate,dtype="float32",blocksize=int(input_rate*.032),callback=callback):
                    while not self.stop_event.wait(.05): pass
        except Exception as error:
            self.log("capture_error", message=str(error))
            self.stop_event.set()
        finally:
            self.capture_done.set()

    def _submit(self, identifier, samples, final, start):
        if not len(samples): return
        job = (identifier,samples.copy(),final,start,time.perf_counter())
        with self.condition:
            if final:
                self.partials.pop(identifier,None)
                self.finals.append(job)  # Finals are never discarded/coalesced.
            else: self.partials[identifier] = job
            self.condition.notify()

    def _vad(self, directory):
        original=None
        try:
            reducer=None
            if self.config.get('noise_reduction',True):
                try:reducer=NoiseReducer()
                except Exception as error:
                    self.log('noise_reduction_unavailable',message=str(error))
                    with self.lock:self.metrics['noise_warning']=str(error)
            with self.lock:self.metrics['noise_reduction']=reducer is not None
            original=wave.open(str(self.session_dir/'original.wav'),'wb')
            original.setnchannels(1);original.setsampwidth(2);original.setframerate(RATE)
            config = sherpa_onnx.VadModelConfig()
            config.silero_vad.model = str(directory / "silero_vad.int8.onnx")
            config.silero_vad.threshold = self.config["vad_threshold"]
            config.silero_vad.min_silence_duration = self.config["silence"]
            config.silero_vad.min_speech_duration = .3
            config.silero_vad.max_speech_duration = 6.0
            config.sample_rate = RATE
            vad = sherpa_onnx.VoiceActivityDetector(config,buffer_size_in_seconds=30)
            last_partial, total, pause_padding = 0, 0, 0
            owners = AudioWindowOwners()
            def collect():
                nonlocal last_partial
                while not vad.empty():
                    segment = vad.front
                    value = np.asarray(segment.samples,dtype=np.float32).copy()
                    start = int(segment.start)
                    self._submit(owners.owner(start),value,True,start/RATE)
                    vad.pop(); last_partial = 0
            while not self.capture_done.is_set() or not self.audio.empty():
                try: block = self.audio.get(timeout=.1)
                except queue.Empty: continue
                if isinstance(block,dict):
                    block=block['pause']; pause_padding += len(block)
                if isinstance(block,tuple):
                    block,rate = block
                    if rate != RATE:
                        divisor = math.gcd(rate,RATE)
                        block = resample_poly(block,RATE//divisor,rate//divisor).astype(np.float32)
                block = np.asarray(block,dtype=np.float32)
                original.writeframesraw((np.clip(block,-1,1)*32767).astype('<i2').tobytes())
                if reducer:block=reducer.process(block)
                if not len(block):continue
                if self.raw:
                    self.raw.writeframesraw((np.clip(block,-1,1)*32767).astype("<i2").tobytes())
                    self.raw_sink.flush()
                total += len(block)
                vad.accept_waveform(block)
                collect()
                speech = bool(vad.is_speech_detected)
                with self.lock:
                    self.metrics.update(rms=float(np.sqrt(np.mean(block**2))) if len(block) else 0,speech=speech,captured_seconds=(total-pause_padding)/RATE)
                if speech:
                    current = np.asarray(vad.current_segment.samples,dtype=np.float32)
                    # Bound full-window work to six seconds, while continuing
                    # previews through the whole window. Pending previews coalesce.
                    if len(current) >= RATE and len(current)-last_partial >= RATE*(1 if last_partial == 0 else self.config["partial_interval"]):
                        last_partial = len(current)
                        start = int(vad.current_segment.start)
                        self._submit(owners.owner(start),current,False,start/RATE)
            if reducer:
                tail=reducer.flush()
                if len(tail):
                    if self.raw:
                        self.raw.writeframesraw((np.clip(tail,-1,1)*32767).astype('<i2').tobytes());self.raw_sink.flush()
                    total+=len(tail);vad.accept_waveform(tail)
            vad.flush(); collect()
            with self.lock:self.metrics['captured_seconds']=(total-pause_padding)/RATE
            with self.lock: self.phase = "stopping"
            self.log("capture_drained", audio_seconds=total/RATE)
        except Exception as error:
            self.log("vad_error", message=str(error)); self.stop_event.set()
        finally:
            if original:original.close()
            with self.condition: self.vad_done = True; self.condition.notify_all()

    def _run(self, samples):
        decoder = None
        capture = None
        vad_thread = None
        try:
            name = self.config["model"]
            directory = speech_model_dir(name)
            began = time.perf_counter()
            decoder = self.decoder(name,self.config['threads'])
            self.log("model_ready", model=name,load_seconds=round(time.perf_counter()-began,3))
            if self.stop_event.is_set(): return
            self.raw_sink = (self.session_dir/"audio.wav").open("w+b")
            self.raw = wave.open(self.raw_sink,"wb")
            self.raw.setnchannels(1); self.raw.setsampwidth(2); self.raw.setframerate(RATE)
            with self.lock: self.phase = "recording"
            vad_thread = threading.Thread(target=self._vad,args=(directory,),daemon=True)
            capture = threading.Thread(target=self._capture,args=(samples,),daemon=True)
            vad_thread.start(); capture.start()
            processed_ends = {}
            last_final = None
            while True:
                with self.condition:
                    while not self.finals and not self.partials and not self.vad_done: self.condition.wait(.1)
                    if self.finals: job = self.finals.popleft()
                    elif self.partials:
                        key = min(self.partials)
                        job = self.partials.pop(key)
                    else: break
                identifier,audio,final,start,queued = job
                endpoint = round(start*RATE)+len(audio)
                # Silero triggers after speech onset, especially for quiet
                # consonants. Restore captured pre-roll without crossing the
                # preceding finalized window or changing this window's owner.
                onset=round(start*RATE)
                floor=last_final[2] if last_final is not None and last_final[0]!=identifier else 0
                pre_start=max(floor,onset-int(1.2*RATE))
                if pre_start<onset:
                    with (self.session_dir/'audio.wav').open('rb') as source:
                        source.seek(44+pre_start*2)
                        pre=np.frombuffer(source.read((onset-pre_start)*2),dtype='<i2').astype(np.float32)/32768
                    audio=np.concatenate((pre,audio))
                previous_end,previous_final = processed_ends.get(identifier,(-1,False))
                if not final and (endpoint < previous_end or (endpoint == previous_end and previous_final)):
                    self.log("stale_decode_skipped",utterance=identifier,final=final)
                    continue
                with self.lock: self.metrics["in_flight"] = True
                with self.lock: self.metrics["stage"] = "decode"
                rms = float(np.sqrt(np.mean(audio**2)))
                text, raw_text, elapsed = "", "", 0.0
                # These windows have already passed Silero speech detection.
                # Whole-window RMS includes pauses and must not veto quiet speech.
                if rms >= .0002:
                    t = time.perf_counter()
                    decode_audio = audio
                    if rms < self.config["minimum_rms"]:
                        decode_audio = np.clip(audio*min(8,.02/max(rms,1e-8)),-1,1)
                        self.log('quiet_speech_gain',utterance=identifier,rms=round(rms,5))
                    stream = decoder.create_stream(); stream.accept_waveform(RATE,decode_audio); decoder.decode_stream(stream)
                    raw_text = stream.result.text
                    elapsed = time.perf_counter()-t
                    text = accepted_english(raw_text)
                with self.lock:
                    self.ledger.update(identifier,text,final,start,revision=True,full_window=True)
                    processed_ends[identifier] = (endpoint,final)
                    self.metrics.update(in_flight=False,decode_seconds=round(elapsed,3),rtf=round(elapsed/max(.001,len(audio)/RATE),3))
                    snapshot = self.ledger.text()
                if final:
                    try:
                        if last_final is not None:
                            prior_id,prior_audio,prior_end = last_final
                            gap = round(start*RATE)-prior_end
                            with self.lock:
                                previous_text=self.ledger.entries[prior_id].best
                                current_text=self.ledger.entries[identifier].best
                            import re
                            complete_boundary=bool(re.search(r'[.!?][\"\']?$',previous_text) and re.match(r'^[A-Z]',current_text))
                            if prior_id != identifier and not complete_boundary and 0 <= gap <= int(1.8*RATE):
                                # VAD gaps may contain quiet words. Recover the
                                # original continuous PCM, never manufacture silence.
                                boundary_start = max(0,prior_end-min(len(prior_audio),3*RATE))
                                boundary_end = round(start*RATE)+min(len(audio),3*RATE)
                                with (self.session_dir/"audio.wav").open("rb") as capture_file:
                                    # This writer emits a standard mono PCM16 RIFF
                                    # header (44 bytes); its length is updated on close.
                                    capture_file.seek(44+boundary_start*2)
                                    pcm = capture_file.read((boundary_end-boundary_start)*2)
                                boundary_audio = np.frombuffer(pcm,dtype="<i2").astype(np.float32)/32768
                                boundary_stream = decoder.create_stream()
                                boundary_stream.accept_waveform(RATE,boundary_audio)
                                with self.lock: self.metrics.update(in_flight=True,stage="boundary")
                                repair_began = time.perf_counter()
                                decoder.decode_stream(boundary_stream)
                                bridge = accepted_english(boundary_stream.result.text)
                                with self.lock:
                                    previous = self.ledger.entries[prior_id].best
                                    current = self.ledger.entries[identifier].best
                                    repaired = reconcile_boundary(previous,current,bridge)
                                    if repaired:
                                            self.ledger.update(prior_id,repaired[0],True,revision=True,full_window=True,allow_trim=True)
                                            self.ledger.update(identifier,repaired[1],True,revision=True,full_window=True,allow_trim=True)
                                self.log("boundary_redecode",left=prior_id,right=identifier,applied=bool(repaired),raw=bridge,
                                         decode_seconds=round(time.perf_counter()-repair_began,3))
                    except Exception as repair_error:
                        self.log("boundary_redecode_error", message=str(repair_error), action="original transcripts retained")
                    last_final = (identifier,audio,endpoint)
                with self.lock: snapshot = self.ledger.text()
                with self.lock: self.metrics.update(in_flight=False,stage="idle")
                self.log("decode", utterance=identifier,final=final,audio_start=start,audio_end=endpoint/RATE,audio_seconds=round(len(audio)/RATE,3),decode_seconds=round(elapsed,3),
                         queue_seconds=round(time.perf_counter()-queued-elapsed,3),rms=round(rms,5),raw=raw_text,accepted=text,retained_chars=len(snapshot))
                self._save()
                if final and text: SPEAKERS.submit(identifier,audio,text)
                LANGUAGE.submit(self.ledger.snapshot()[0])
        except Exception as error:
            self.log("worker_error", message=str(error)); self.stop_event.set()
        finally:
            self.stop_event.set()
            if capture: capture.join(timeout=5)
            if vad_thread: vad_thread.join(timeout=5)
            if self.raw: self.raw.close(); self.raw=None
            if self.raw_sink: self.raw_sink.close(); self.raw_sink=None
            with self.lock:
                self.ledger.finalize_all()
                self.metrics.update(in_flight=False,speech=False,stage="idle")
                self.phase = "error" if self.failure else "done"
            self.log("session_complete", text_chars=len(self.ledger.text()),success=self.failure is None)
            self._save()
            LANGUAGE.submit(self.ledger.snapshot()[0],flush=True)

    def _save(self):
        if not self.session_dir: return
        with self.lock:
            state = self.state()
            text = self.ledger.text()
        (self.session_dir/"transcript.txt").write_text(text,encoding="utf-8")
        (self.session_dir/"result.json").write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding="utf-8")


LAB = Lab()
TOKEN = secrets.token_urlsafe(24)


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,data,status=200,content_type="application/json; charset=utf-8"):
        if isinstance(data,(dict,list)): data=json.dumps(data,ensure_ascii=False).encode()
        elif isinstance(data,str): data=data.encode()
        self.send_response(status); self.send_header("Content-Type",content_type); self.send_header("Content-Length",str(len(data)))
        self.send_header("Cache-Control","no-store"); self.send_header("X-Content-Type-Options","nosniff"); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path=urlparse(self.path).path
        if path == "/api/library": return self.reply(STORE.library())
        if path.startswith("/api/records/"):
            try: return self.reply(STORE.record(path.rsplit('/',1)[-1]))
            except (ValueError,OSError) as error: return self.reply({'error':str(error)},404)
        web_root = WEB_ROOT
        if path in ("/","/overlay") and (web_root / "index.html").is_file():
            return self.reply((web_root / "index.html").read_text(encoding="utf-8"),content_type="text/html; charset=utf-8")
        if path == "/lab": return self.reply((ROOT/"asr_lab.html").read_text(encoding="utf-8").replace("__TOKEN__",TOKEN),content_type="text/html; charset=utf-8")
        if path == "/app-icon.png" and (web_root / 'app-icon.png').is_file():
            return self.reply((web_root / 'app-icon.png').read_bytes(),content_type='image/png')
        if path.startswith("/assets/"):
            asset = (web_root / path.lstrip("/")).resolve()
            if asset.is_relative_to(web_root.resolve()) and asset.is_file():
                return self.reply(asset.read_bytes(),content_type=mimetypes.guess_type(asset.name)[0] or "application/octet-stream")
        if path == "/api/state": return self.reply(LAB.state())
        if path == '/api/model-downloads':return self.reply({'downloads':DOWNLOADS.snapshot(),'models':models()})
        if path == "/api/config":
            try:
                default=sd.default.device[0]
                devices=[{"id":i,"name":d["name"],"default":i==default} for i,d in enumerate(sd.query_devices()) if d["max_input_channels"]>0]
            except Exception: devices=[]
            return self.reply({"version":BUILD_VERSION,"devices":devices,"models":models(),"session_token":TOKEN,
                               "settings":STORE.settings(),"translation_configured":bool(LANGUAGE.key),
                               "grammar_automatic":True,"translation_automatic":True})
        if path == "/api/export":
            result = LAB.state()
            with LAB.lock:
                logfile = LAB.session_dir/"events.jsonl" if LAB.session_dir else None
                result["logs"] = [json.loads(line) for line in logfile.read_text(encoding="utf-8").splitlines()] if logfile and logfile.exists() else list(LAB.logs)
            return self.reply(result)
        self.reply({"error":"not found"},404)
    def do_POST(self):
        if self.headers.get("X-Lingo-Token") != TOKEN: return self.reply({"error":"invalid session token"},403)
        try:
            size=int(self.headers.get("Content-Length",0))
            if size > 150*1024*1024: raise ValueError("文件最大 150 MB；请用 PCM WAV")
            body=self.rfile.read(size)
            path=urlparse(self.path).path
            if path == "/api/courses":
                return self.reply(STORE.create_course(json.loads(body)))
            elif path == '/api/rename-record':
                value=json.loads(body);return self.reply(STORE.rename_record(value['id'],value['title']))
            elif path == '/api/download-model':
                return self.reply(DOWNLOADS.start(json.loads(body)['model']))
            elif path == '/api/export-text':
                value=json.loads(body);text=value.get('text','')
                if not text.strip():raise ValueError('没有可导出的内容')
                format=value.get('format','txt')
                if format not in ('txt','docx'):raise ValueError('导出格式无效')
                import sys
                webview=sys.modules.get('webview')
                if webview and webview.windows:
                    filename=Path(value.get('filename','课堂录音')).stem+'.'+format
                    paths=webview.windows[0].create_file_dialog(webview.FileDialog.SAVE,save_filename=filename,file_types=('Word 文档 (*.docx)',) if format=='docx' else ('文本文件 (*.txt)',))
                    if paths:
                        destination=Path(paths[0]).with_suffix('.'+format)
                        if format=='docx':
                            from word_export import word_document
                            destination.write_bytes(word_document(text,Path(filename).stem))
                        else:destination.write_text(text,encoding='utf-8-sig')
                        return self.reply({'native':True,'saved':True})
                    return self.reply({'native':True,'saved':False})
                return self.reply({'native':False})
            elif path == '/api/export-word':
                from word_export import word_document,MIME
                value=json.loads(body)
                return self.reply(word_document(value.get('text',''),Path(value.get('filename','课堂记录')).stem),content_type=MIME)
            elif path == '/api/close-overlay':
                import sys
                webview=sys.modules.get('webview')
                if webview:
                    for window in webview.windows[:]:
                        if window.title=='LingoClass 字幕':window.destroy()
                return self.reply({'ok':True})
            elif path == "/api/preferences":
                return self.reply(STORE.update_settings(json.loads(body)))
            elif path == "/api/subtitle-window":
                import sys
                webview=sys.modules.get('webview')
                if webview and webview.windows:
                    existing=next((w for w in webview.windows if w.title=='LingoClass 字幕'),None)
                    if existing: existing.show()
                    else:
                        window=webview.create_window('LingoClass 字幕',f'http://127.0.0.1:{self.server.server_port}/overlay',width=760,height=210,min_size=(420,140),on_top=True,frameless=True,easy_drag=True,transparent=True,background_color='#202124')
                        window.events.shown += lambda: apply_overlay_material(window)
                        window.events.loaded += lambda: apply_overlay_material(window)
                    return self.reply({'native':True})
                return self.reply({'native':False})
            elif path == "/api/translation-settings":
                settings=json.loads(body)
                endpoint=settings.get('endpoint',LANGUAGE.url).rstrip('/')
                from urllib.parse import urlsplit
                host=urlsplit(endpoint).hostname or ''
                if not endpoint.startswith('https://') or not (host.endswith('.aliyuncs.com') or host == 'dashscope.aliyuncs.com' or host == 'maas.qianwenaiapi.com'):
                    raise ValueError('请使用阿里云官方 HTTPS 接口地址')
                with LANGUAGE.lock:
                    LANGUAGE.key=settings.get('key','').strip() or LANGUAGE.key
                    LANGUAGE.url=endpoint
                    # Retry queued errors without changing already completed pairs.
                    for identifier,row in LANGUAGE.results.items():
                        if row['status']=='error':
                            LANGUAGE.pending[identifier]=(LANGUAGE.generation,row['original'])
                persisted=False
                if settings.get('key','').strip():
                    try:
                        import keyring
                        keyring.set_password('LingoClass','qwen-api-key',LANGUAGE.key)
                        persisted=True
                    except Exception: pass
                STORE.update_settings({'translation_endpoint':endpoint})
                return self.reply({'ok':True,'configured':bool(LANGUAGE.key),'persisted':persisted})
            elif path == "/api/grammar":
                from grammar_model import GRAMMAR
                with LAB.lock:
                    if LAB.phase in ('loading', 'recording', 'stopping'):
                        raise ValueError('请先停止并完成转写，再运行语法校对')
                    original = LAB.ledger.text()
                    directory = LAB.session_dir
                if not original.strip(): raise ValueError('还没有可校对的英文')
                result = {'model':'vennify/t5-base-grammar-correction','original':original,'rows':GRAMMAR.correct(original)}
                if directory:
                    (directory/'grammar.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
                return self.reply(result)
            elif path == "/api/stop": LAB.stop()
            elif path == "/api/pause": LAB.pause()
            elif path == "/api/resume": LAB.resume()
            elif path == "/api/start": LAB.start(json.loads(body))
            elif path == "/api/file":
                config=json.loads(self.headers.get("X-Lingo-Config","{}"))
                LAB.start(config,read_wav(body))
            else: return self.reply({"error":"not found"},404)
            self.reply({"ok":True})
        except Exception as error: self.reply({"error":str(error)},400)


def apply_overlay_material(window):
    import sys
    if sys.platform!='win32':return
    import ctypes
    class Accent(ctypes.Structure):
        _fields_=[('state',ctypes.c_int),('flags',ctypes.c_int),('color',ctypes.c_uint),('animation',ctypes.c_int)]
    class Data(ctypes.Structure):
        _fields_=[('attribute',ctypes.c_int),('data',ctypes.c_void_p),('size',ctypes.c_size_t)]
    hwnd=int(window.native.Handle.ToInt64())
    accent=Accent(4,2,0x99251f1c,0)
    data=Data(19,ctypes.addressof(accent),ctypes.sizeof(accent))
    ctypes.windll.user32.SetWindowCompositionAttribute(ctypes.c_void_p(hwnd),ctypes.byref(data))
    corner=ctypes.c_int(2)
    ctypes.windll.dwmapi.DwmSetWindowAttribute(ctypes.c_void_p(hwnd),33,ctypes.byref(corner),4)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--port",type=int,default=8785); parser.add_argument("--open-browser",action="store_true"); parser.add_argument("--desktop",action="store_true"); args=parser.parse_args()
    server=ThreadingHTTPServer(("127.0.0.1",args.port),Handler)
    def warmup():
        try: LAB.decoder('small',4)
        except Exception as error: LAB.log('warmup_error',message=str(error))
    # Model construction must finish before Python tears down native libraries.
    threading.Thread(target=warmup,daemon=False).start()
    print(f"LingoClass ASR MVP: http://127.0.0.1:{args.port}",flush=True)
    if args.desktop:
        def serve(): server.serve_forever()
        threading.Thread(target=serve,daemon=True).start()
        import webview
        import sys
        webview.create_window("LingoClass",f"http://127.0.0.1:{args.port}",width=1000,height=650,min_size=(800,550),background_color="#ffffff",vibrancy=sys.platform=='darwin',text_select=True)
        icon_path=ICON_PATH
        try: webview.start(icon=str(icon_path) if icon_path.is_file() else None)
        finally:
            LAB.stop()
            if LAB.worker: LAB.worker.join(timeout=60)
            SPEAKERS.close();LANGUAGE.close()
            server.shutdown(); server.server_close()
        return
    if args.open_browser:
        import webbrowser
        threading.Timer(.5, lambda: webbrowser.open(f"http://127.0.0.1:{args.port}/")).start()
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        LAB.stop()
        if LAB.worker: LAB.worker.join()
        SPEAKERS.close();LANGUAGE.close()
        server.server_close()


if __name__=="__main__": main()
