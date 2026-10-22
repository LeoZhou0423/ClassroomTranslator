"""Incremental, coalesced local previews, independent of final Whisper work."""

import threading
import time
from collections import OrderedDict

import numpy as np
import sherpa_onnx
from app_paths import BUNDLE_ROOT, FROZEN, MODEL_ROOT

MODEL_NAME = "sherpa-onnx-streaming-zipformer-en-2023-06-26"
FILES = {
    "encoder": "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
    "decoder": "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
    "joiner": "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
    "tokens": "tokens.txt",
}


def model_dir():
    return (
        MODEL_ROOT / "streaming-en" if FROZEN else BUNDLE_ROOT / "Tools/sherpa/models" / MODEL_NAME
    )


def available():
    return all((model_dir() / name).is_file() for name in FILES.values())


def build_recognizer():
    # One inference thread avoids three ONNX sessions spinning idle thread pools
    # between microphone packets, and reserves CPU for capture/final correction.
    return sherpa_onnx.OnlineRecognizer.from_transducer(
        **{key: str(model_dir() / name) for key, name in FILES.items()},
        num_threads=1,
        sample_rate=16000,
        feature_dim=80,
        decoding_method="greedy_search",
        enable_endpoint_detection=False,
        provider="cpu",
    )


class StreamingPreview:
    def __init__(self, recognizer, publish, failure):
        self.recognizer = recognizer
        self.publish = publish
        self.failure = failure
        self.condition = threading.Condition()
        self.jobs = OrderedDict()
        self.closing = False
        self.thread = threading.Thread(target=self.run, name="live-caption-preview", daemon=True)
        self.thread.start()

    def submit(self, identifier, samples, complete, start):
        with self.condition:
            if self.closing:
                return
            previous = self.jobs.get(identifier)
            if previous and (previous[1] or len(previous[0]) > len(samples)):
                return
            self.jobs[identifier] = (samples.copy(), complete, start)
            self.condition.notify()

    def close(self):
        with self.condition:
            self.closing = True
            self.condition.notify_all()
        self.thread.join()

    def run(self):
        identifier = None
        stream = None
        fed = 0
        last_text = ""
        try:
            while True:
                with self.condition:
                    self.condition.wait_for(lambda: self.jobs or self.closing)
                    if not self.jobs:
                        return
                    key, (samples, complete, start) = self.jobs.popitem(last=False)
                if key != identifier:
                    identifier, stream, fed, last_text = key, self.recognizer.create_stream(), 0, ""
                if len(samples) < fed:
                    continue
                began = time.perf_counter()
                stream.accept_waveform(16000, samples[fed:])
                fed = len(samples)
                if complete:
                    stream.accept_waveform(16000, np.zeros(8000, dtype=np.float32))
                    stream.input_finished()
                while self.recognizer.is_ready(stream):
                    self.recognizer.decode_stream(stream)
                text = self.recognizer.get_result(stream).strip()
                if text and (text != last_text or complete):
                    self.publish(
                        key,
                        text,
                        complete,
                        start,
                        len(samples) / 16000,
                        time.perf_counter() - began,
                    )
                    last_text = text
                if complete:
                    identifier, stream = None, None
        except Exception as error:
            with self.condition:
                self.closing = True
                self.jobs.clear()
            self.failure(error)
