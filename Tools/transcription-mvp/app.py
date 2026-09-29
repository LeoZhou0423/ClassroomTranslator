from __future__ import annotations

import queue
import threading
import time
import tkinter as tk
from dataclasses import dataclass
from pathlib import Path
from tkinter import messagebox, ttk

import numpy as np
import sherpa_onnx
import sounddevice as sd

from transcription_core import (
    LocalAgreement,
    acceptable,
    append_text,
    clean,
    format_sentences,
    reconcile_final_segment,
    strip_committed_prefix,
)
from speaker_core import SpeakerRoleAnalyzer, TranscriptItem
from translation_core import LatestTranslationWorker, OpusTranslator, TranslationBlock

ROOT = Path(__file__).resolve().parent
RATE = 16_000


@dataclass(order=True)
class DecodeJob:
    priority: int
    serial: int
    generation: int
    final: bool
    samples: np.ndarray


class WhisperLab:
    def __init__(self, emit):
        self.emit = emit
        self.audio: queue.Queue[np.ndarray] = queue.Queue(maxsize=80)
        self.jobs: queue.PriorityQueue[DecodeJob] = queue.PriorityQueue(maxsize=3)
        self.running = threading.Event()
        self.serial = 0
        self.last_partial_audio = 0
        self.segments: list[TranscriptItem] = []
        self.segment_committed = ""
        self.speaker_analyzer: SpeakerRoleAnalyzer | None = None
        self.agreement = LocalAgreement()
        self.stream = None
        self.generation = 0
        self.translation_worker: LatestTranslationWorker | None = None

    @staticmethod
    def _clear(work_queue):
        try:
            while True:
                work_queue.get_nowait()
        except queue.Empty:
            pass

    def _models(self, model_name: str) -> Path:
        model_dir = ROOT / "models" / f"whisper-{model_name}"
        required = [f"{model_name}-encoder.int8.onnx", f"{model_name}-decoder.int8.onnx", f"{model_name}-tokens.txt", "silero_vad.int8.onnx"]
        missing = [name for name in required if not (model_dir / name).is_file()]
        if missing:
            raise RuntimeError("缺少模型：" + ", ".join(missing) + f"。先运行 download_models.py --model {model_name}")
        return model_dir

    def start(self, device: int | None, model_name: str):
        if self.running.is_set():
            self.emit("log", "录音已经在运行")
            return
        model_dir = self._models(model_name)
        if self.translation_worker is not None:
            self.translation_worker.close()
            self.translation_worker = None
        self.generation += 1
        generation = self.generation
        self._clear(self.audio)
        self._clear(self.jobs)
        self.running.set()
        self.segments = []
        self.segment_committed = ""
        self.speaker_analyzer = None
        self.agreement.reset()
        self.emit("final", "")
        self.emit("partial", "")
        self.emit("translation", "正在加载离线翻译模型…")
        threading.Thread(target=self._decode_loop, args=(generation, model_name, model_dir), daemon=True).start()
        threading.Thread(target=self._vad_loop, args=(generation, model_dir), daemon=True).start()
        self.stream = sd.InputStream(
            device=device, channels=1, samplerate=RATE, dtype="float32",
            blocksize=512,
            callback=lambda data, frames, timing, status: self._audio_callback(
                generation, data, frames, timing, status
            ),
        )
        self.stream.start()

    def stop(self):
        self.running.clear()
        self.generation += 1
        if self.stream:
            self.stream.stop(); self.stream.close(); self.stream = None
        self._clear(self.audio)
        self._clear(self.jobs)

    def _audio_callback(self, generation, data, frames, timing, status):
        if generation != self.generation or not self.running.is_set():
            return
        if status:
            self.emit("log", f"音频状态：{status}")
        try:
            self.audio.put_nowait(data[:, 0].copy())
        except queue.Full:
            self.emit("log", "音频队列溢出：解码过慢")

    def _vad_loop(self, generation, model_dir: Path):
        config = sherpa_onnx.VadModelConfig()
        config.silero_vad.model = str(model_dir / "silero_vad.int8.onnx")
        config.silero_vad.threshold = 0.25
        config.silero_vad.min_silence_duration = 0.7
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.max_speech_duration = 12.0
        config.sample_rate = RATE
        vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=30)
        while self.running.is_set() and generation == self.generation:
            try:
                block = self.audio.get(timeout=0.1)
            except queue.Empty:
                continue
            vad.accept_waveform(block)
            if vad.is_speech_detected:
                current = np.asarray(vad.current_segment.samples, dtype=np.float32).copy()
                if len(current) - self.last_partial_audio >= int(1.5 * RATE):
                    self.last_partial_audio = len(current)
                    self._submit(generation, current, final=False)
            while not vad.empty():
                segment = np.asarray(vad.front.samples, dtype=np.float32).copy()
                vad.pop()
                self.last_partial_audio = 0
                self._submit(generation, segment, final=True)

    def _submit(self, generation: int, samples: np.ndarray, final: bool):
        if generation != self.generation:
            return
        self.serial += 1
        job = DecodeJob(0 if final else 1, self.serial, generation, final, samples)
        if final:
            # A final decode supersedes every queued partial for this VAD segment.
            queued_finals = []
            try:
                while True:
                    old = self.jobs.get_nowait()
                    if old.final:
                        queued_finals.append(old)
            except queue.Empty:
                pass
            for old in queued_finals:
                self.jobs.put_nowait(old)
        else:
            # Only the newest partial matters.
            try:
                while True:
                    old = self.jobs.get_nowait()
                    if old.final:
                        self.jobs.put_nowait(old); break
            except queue.Empty:
                pass
        try:
            self.jobs.put_nowait(job)
        except queue.Full:
            if final:
                self.emit("log", "警告：final 解码队列已满")

    def _decode_loop(self, generation, model_name: str, model_dir: Path):
        recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=str(model_dir / f"{model_name}-encoder.int8.onnx"),
            decoder=str(model_dir / f"{model_name}-decoder.int8.onnx"),
            tokens=str(model_dir / f"{model_name}-tokens.txt"),
            language="", task="transcribe", num_threads=2,
        )
        try:
            self.speaker_analyzer = SpeakerRoleAnalyzer()
            self.emit("log", f"Whisper {model_name}、CAM++ 与 MiniLM 已就绪")
        except Exception as error:
            self.speaker_analyzer = None
            self.emit("log", f"说话人模块降级，转写继续：{error}")
        try:
            backend = OpusTranslator(ROOT / "models" / "opus-mt-en-zh-ct2")
            self.translation_worker = LatestTranslationWorker(
                backend,
                lambda value: self.emit("translation", value),
                lambda value: self.emit("log", value),
            )
            self.emit("translation", "")
            self.emit("log", "OPUS-MT en→zh（CTranslate2 INT8）已就绪")
        except Exception as error:
            self.translation_worker = None
            self.emit("translation", "翻译模型不可用")
            self.emit("log", f"翻译模块降级，转写继续：{error}")
        while generation == self.generation and (self.running.is_set() or not self.jobs.empty()):
            try:
                job = self.jobs.get(timeout=0.1)
            except queue.Empty:
                continue
            if job.generation != generation:
                continue
            started = time.perf_counter()
            stream = recognizer.create_stream()
            stream.accept_waveform(RATE, job.samples)
            recognizer.decode_stream(stream)
            text = clean(stream.result.text)
            elapsed = time.perf_counter() - started
            if not acceptable(text):
                self.emit("log", f"拒绝退化输出 ({elapsed:.2f}s)：{text!r}")
                continue
            if job.final:
                completed = reconcile_final_segment(self.segment_committed, text)
                final = completed
                item_index = len(self.segments)
                item = TranscriptItem(text=completed)
                if self.speaker_analyzer is not None:
                    speaker_id, backfill = self.speaker_analyzer.assign(job.samples, item_index)
                    item.speaker_id = speaker_id
                    if backfill is not None and 0 <= backfill < len(self.segments):
                        self.segments[backfill].speaker_id = speaker_id
                self.segments.append(item)
                if self.speaker_analyzer is not None:
                    self.speaker_analyzer.update_roles(self.segments)
                self.segment_committed = ""
                self.agreement.reset()
                self.emit("final", self._render_final())
                self._submit_translation()
                self.emit("partial", "")
                label = self._speaker_name(item.speaker_id)
                self.emit("log", f"FINAL {label} · {len(job.samples)/RATE:.2f}s，解码 {elapsed:.2f}s：{final}")
            else:
                remainder = strip_committed_prefix(text, self.segment_committed)
                stable, volatile = self.agreement.update(remainder)
                if stable:
                    self.segment_committed = append_text(self.segment_committed, stable)
                    self.emit("final", self._render_final())
                    self._submit_translation()
                    remainder = strip_committed_prefix(remainder, stable)
                    self.agreement.reset()
                    if remainder:
                        self.agreement.update(remainder)
                    volatile = remainder
                    self.emit("log", f"PROMOTE：{stable}")
                self.emit("partial", (("[…]  " + volatile) if volatile else ""))
                self.emit("log", f"PARTIAL {len(job.samples)/RATE:.2f}s，解码 {elapsed:.2f}s")

    def _speaker_name(self, speaker_id: int | None) -> str:
        if speaker_id is None:
            return "说话人待确认"
        if self.speaker_analyzer is None:
            return f"说话人 {speaker_id + 1}"
        return self.speaker_analyzer.names({item.speaker_id for item in self.segments if item.speaker_id is not None}).get(
            speaker_id, f"说话人 {speaker_id + 1}"
        )

    def _render_final(self) -> str:
        ids = {item.speaker_id for item in self.segments if item.speaker_id is not None}
        names = self.speaker_analyzer.names(ids) if self.speaker_analyzer is not None else {}
        grouped: list[TranscriptItem] = []
        for item in self.segments:
            if grouped and grouped[-1].speaker_id == item.speaker_id:
                grouped[-1].text = append_text(grouped[-1].text, item.text)
            else:
                grouped.append(TranscriptItem(item.text, item.speaker_id))
        blocks = []
        for item in grouped:
            label = names.get(item.speaker_id, f"说话人 {item.speaker_id + 1}" if item.speaker_id is not None else "说话人待确认")
            body = format_sentences(item.text).replace("\n", "\n    ")
            blocks.append(f"{label}: {body}")
        if self.segment_committed:
            body = format_sentences(self.segment_committed).replace("\n", "\n    ")
            blocks.append(f"识别中: {body}")
        return "\n".join(blocks)

    def _translation_blocks(self) -> list[TranslationBlock]:
        ids = {item.speaker_id for item in self.segments if item.speaker_id is not None}
        names = self.speaker_analyzer.names(ids) if self.speaker_analyzer is not None else {}
        blocks: list[TranslationBlock] = []
        for item in self.segments:
            label = names.get(item.speaker_id, f"说话人 {item.speaker_id + 1}" if item.speaker_id is not None else "说话人待确认")
            if blocks and blocks[-1].label == label:
                previous = blocks[-1]
                blocks[-1] = TranslationBlock(label, append_text(previous.text, item.text))
            else:
                blocks.append(TranslationBlock(label, item.text))
        if self.segment_committed:
            blocks.append(TranslationBlock("识别中", self.segment_committed))
        return blocks

    def _submit_translation(self) -> None:
        if self.translation_worker is not None:
            self.translation_worker.submit(self._translation_blocks())


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("LingoClass · Whisper 转写实验台")
        self.geometry("900x680")
        self.events = queue.Queue()
        self.lab = WhisperLab(lambda kind, value: self.events.put((kind, value)))
        devices = [(i, d["name"]) for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0]
        ttk.Label(self, text="输入设备").pack(anchor="w", padx=14, pady=(12, 2))
        self.device = ttk.Combobox(self, state="readonly", values=[f"{i}: {name}" for i, name in devices])
        self.device.pack(fill="x", padx=14)
        if devices: self.device.current(0)
        model_row = ttk.Frame(self); model_row.pack(fill="x", padx=14, pady=(8, 0))
        ttk.Label(model_row, text="Whisper 模型").pack(side="left")
        self.model = ttk.Combobox(model_row, state="readonly", width=12, values=["tiny", "small"])
        self.model.pack(side="left", padx=8)
        small_ready = (ROOT / "models" / "whisper-small" / "small-decoder.int8.onnx").is_file()
        self.model.set("small" if small_ready else "tiny")
        bar = ttk.Frame(self); bar.pack(fill="x", padx=14, pady=10)
        ttk.Button(bar, text="开始", command=self.start_lab).pack(side="left")
        ttk.Button(bar, text="停止", command=self.stop_lab).pack(side="left", padx=8)
        ttk.Label(self, text="实时假设（[…] 后为未稳定区域）").pack(anchor="w", padx=14)
        self.partial = tk.Text(self, height=5, wrap="word", fg="#b36b00"); self.partial.pack(fill="x", padx=14, pady=4)
        ttk.Label(self, text="已定稿段落").pack(anchor="w", padx=14)
        self.final = tk.Text(self, height=10, wrap="word"); self.final.pack(fill="both", expand=True, padx=14, pady=4)
        ttk.Label(self, text="中文翻译（仅翻译稳定内容）").pack(anchor="w", padx=14)
        self.translation = tk.Text(self, height=8, wrap="word", fg="#245b9e"); self.translation.pack(fill="both", expand=True, padx=14, pady=4)
        ttk.Label(self, text="VAD / 解码日志").pack(anchor="w", padx=14)
        self.log = tk.Text(self, height=8, wrap="word", fg="#555"); self.log.pack(fill="x", padx=14, pady=(4, 12))
        self.after(50, self.poll)
        self.protocol("WM_DELETE_WINDOW", self.close)

    def start_lab(self):
        try:
            raw = self.device.get().split(":", 1)[0]
            self.lab.start(int(raw) if raw else None, self.model.get())
        except Exception as error:
            messagebox.showerror("无法启动", str(error))

    def stop_lab(self): self.lab.stop()
    def close(self): self.lab.stop(); self.destroy()

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                widget = {"partial": self.partial, "final": self.final, "translation": self.translation, "log": self.log}[kind]
                if kind == "log": widget.insert("end", value + "\n"); widget.see("end")
                else: widget.delete("1.0", "end"); widget.insert("1.0", value)
        except queue.Empty:
            pass
        self.after(50, self.poll)


if __name__ == "__main__":
    App().mainloop()
