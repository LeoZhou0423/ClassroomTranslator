from __future__ import annotations

import queue
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class TranslationBlock:
    label: str
    text: str


def render_translations(blocks: list[TranslationBlock], translations: list[str]) -> str:
    return "\n".join(
        f"{block.label}: {translated}"
        for block, translated in zip(blocks, translations)
        if translated.strip()
    )


class OpusTranslator:
    """Offline English-to-Chinese OPUS-MT inference through CTranslate2."""

    def __init__(self, model_dir: Path):
        import ctranslate2
        import sentencepiece as spm

        required = ("model.bin", "config.json", "source.spm", "target.spm")
        missing = [name for name in required if not (model_dir / name).is_file()]
        if missing:
            raise RuntimeError("缺少翻译模型：" + ", ".join(missing))
        self.source = spm.SentencePieceProcessor(model_file=str(model_dir / "source.spm"))
        self.target = spm.SentencePieceProcessor(model_file=str(model_dir / "target.spm"))
        self.translator = ctranslate2.Translator(
            str(model_dir), device="cpu", compute_type="int8", inter_threads=1, intra_threads=2
        )

    def translate(self, text: str) -> str:
        # This OPUS checkpoint is multilingual on the target side. Without an
        # explicit Mandarin Simplified token it can mix scripts and repeat.
        tokens = self.source.encode(">>cmn_Hans<< " + text.strip(), out_type=str)
        if not tokens:
            return ""
        tokens.append("</s>")
        result = self.translator.translate_batch(
            [tokens], beam_size=1, max_decoding_length=256, return_scores=False
        )[0]
        return self.target.decode(result.hypotheses[0]).strip()


class LatestTranslationWorker:
    """Translate only the newest stable snapshot and discard stale results."""

    def __init__(
        self,
        backend,
        on_result: Callable[[str], None],
        on_log: Callable[[str], None],
    ):
        self.backend = backend
        self.on_result = on_result
        self.on_log = on_log
        self.jobs: queue.Queue[tuple[int, list[TranslationBlock]] | None] = queue.Queue(maxsize=1)
        self.revision = 0
        self.cache: dict[str, str] = {}
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def submit(self, blocks: list[TranslationBlock]) -> None:
        self.revision += 1
        job = (self.revision, blocks)
        try:
            self.jobs.get_nowait()
        except queue.Empty:
            pass
        self.jobs.put_nowait(job)

    def close(self) -> None:
        self.revision += 1
        try:
            self.jobs.get_nowait()
        except queue.Empty:
            pass
        self.jobs.put_nowait(None)

    def _run(self) -> None:
        while True:
            job = self.jobs.get()
            if job is None:
                return
            revision, blocks = job
            try:
                output = []
                for block in blocks:
                    translated = self.cache.get(block.text)
                    if translated is None:
                        translated = self.backend.translate(block.text)
                        self.cache[block.text] = translated
                    output.append(translated)
                if revision == self.revision:
                    self.on_result(render_translations(blocks, output))
            except Exception as error:
                self.on_log(f"翻译失败，转写继续：{error}")
