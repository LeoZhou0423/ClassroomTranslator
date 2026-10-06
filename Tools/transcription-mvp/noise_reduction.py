"""Streaming speech enhancement: keep sample order and flush the tail."""
import numpy as np
import sherpa_onnx
from app_paths import MODEL_ROOT

class NoiseReducer:
    def __init__(self):
        model=MODEL_ROOT/'denoise'/'gtcrn_simple.onnx'
        if not model.is_file():raise FileNotFoundError('降噪模型缺失，当前使用原始音频')
        config=sherpa_onnx.OnlineSpeechDenoiserConfig(model=sherpa_onnx.OfflineSpeechDenoiserModelConfig(
            gtcrn=sherpa_onnx.OfflineSpeechDenoiserGtcrnModelConfig(model=str(model)),
            num_threads=1,provider='cpu'))
        if not config.validate():raise ValueError('降噪模型配置无效')
        self.engine=sherpa_onnx.OnlineSpeechDenoiser(config)
        # Enhancement can damage quiet consonants. Keep an aligned dry signal
        # rather than replacing speech with the model output wholesale.
        self.pending=np.empty(0,dtype=np.float32)
        self.failed=False

    def _blend(self,enhanced):
        enhanced=np.asarray(enhanced,dtype=np.float32)
        count=len(enhanced)
        if count>len(self.pending):raise ValueError('降噪输出长度异常')
        output=.65*self.pending[:count]+.35*enhanced
        self.pending=self.pending[count:]
        return output.astype(np.float32)

    def process(self,samples):
        samples=np.ascontiguousarray(samples,dtype=np.float32)
        if self.failed:return samples
        self.pending=np.concatenate((self.pending,samples))
        try:
            return self._blend(self.engine.run(samples,16000).samples)
        except Exception:
            # A failed enhancer must not stop capture or discard buffered audio.
            self.failed=True
            output=self.pending
            self.pending=np.empty(0,dtype=np.float32)
            return output

    def flush(self):
        if self.failed:return np.empty(0,dtype=np.float32)
        try:
            output=self._blend(self.engine.flush().samples)
        except Exception:
            output=np.empty(0,dtype=np.float32)
            self.failed=True
        # Preserve any tail even if the backend returned too few samples.
        output=np.concatenate((output,self.pending))
        self.pending=np.empty(0,dtype=np.float32)
        return output
