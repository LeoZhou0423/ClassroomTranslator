#!/usr/bin/env python3
"""Waveform -> kaldi fbank -> CAM++ speaker embedding wrapper (torch).

Purpose: put the log-mel frontend INSIDE the CoreML model so the Swift app
feeds raw PCM only (same pattern as AccentECAPA). The frontend is an exact
port of kaldi-native-fbank v1.22.3 (the library sherpa-onnx 1.13.8 links),
using sherpa's FeatureExtractorConfig overrides:

  dither = 0, snip_edges = false, low_freq = 20, high_freq = -400
  (= 7600 Hz at 16 kHz), num_mel_bins = 80, frame 25 ms / shift 10 ms,
  FFT 512 (round_to_power_of_two), povey window, preemph 0.97,
  remove_dc_offset, use_power, use_log_fbank with float-eps floor.

sherpa additionally applies per-utterance mean normalization before the
model (ONNX metadata: feature_normalize_type=global-mean); the wrapper
reproduces it over the valid frames only.

Frame count follows sherpa's UNFLUSHED snip_edges=false path (the Python
embedding API never calls input_finished):

  count(L) = clamp(floor((L - 280) / 160) + 1, 0, 399)

Fixed-shape design (why): torch.jit.trace bakes Python-level shape
manipulations (FCM reshape, CAM seg_pooling) as constants, so a dynamic-T
graph cannot convert correctly. Instead the wrapper always processes 399
frames of a fixed 64000-sample window, zeroes rows >= count after CMN
(reproducing the zero-padding the shorter reference graph sees) and masks
the statistics pooling to the conv-T positions the reference graph has.

Inputs
  waveform   [1, 64000] float32  - 16 kHz mono, zero padded to 4 s
  numSamples [1, 1]      float32  - valid length L in samples (>= 9600)
Output
  embedding  [1, 192]    float32
"""
from __future__ import annotations

import math
import sys
from collections import OrderedDict
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = Path(__file__).parent

WAVE_LEN = 64000          # 4 s @ 16 kHz (CoreML fixed input)
FRAME_LEN = 400           # 25 ms
FRAME_SHIFT = 160         # 10 ms
FFT_LEN = 512
NUM_FRAMES = 399          # frames of a full 64000-sample window
NUM_MEL = 80
NUM_FFT_BINS = FFT_LEN // 2   # 256: kaldi mel bank iterates i < 256
LOG_EPS = float(np.finfo(np.float32).eps)   # C++ std::numeric_limits<float>::epsilon()
MIN_SAMPLES = 9600        # product floor: 0.6 s


def _frame_index() -> torch.Tensor:
    """Static sample indices [399, 400] with snip_edges=false start reflection.

    FirstSampleOfFrame(f) = f*160 - 120 (midpoint alignment). Negative
    indices of frame 0 reflect around the signal start: -1 -> 0, -2 -> 1, ...
    (single reflection step is enough: min index = -120 -> 119).
    Upper clamp reads the zero pad of the fixed 64000-sample window; rows
    beyond count(L) are masked out anyway.
    """
    starts = torch.arange(NUM_FRAMES, dtype=torch.int64).unsqueeze(1) * FRAME_SHIFT - (FRAME_LEN - FRAME_SHIFT) // 2
    idx = starts + torch.arange(FRAME_LEN, dtype=torch.int64)
    idx = torch.where(idx < 0, -idx - 1, idx)
    return idx.clamp(0, WAVE_LEN - 1)


def _povey_window() -> torch.Tensor:
    n = np.arange(FRAME_LEN, dtype=np.float64)
    a = 2.0 * math.pi / (FRAME_LEN - 1)
    w = np.power(0.5 - 0.5 * np.cos(a * n), 0.85)
    return torch.from_numpy(w.astype(np.float32))


def _dft_matrices() -> tuple[torch.Tensor, torch.Tensor]:
    """Real/imag DFT rows for bins 0..256 (kissfft-compatible, unnormalized)."""
    k = np.arange(NUM_FFT_BINS + 1, dtype=np.float64).reshape(-1, 1)
    n = np.arange(FFT_LEN, dtype=np.float64).reshape(1, -1)
    ang = 2.0 * math.pi * k * n / FFT_LEN
    return (
        torch.from_numpy(np.cos(ang).astype(np.float32)),
        torch.from_numpy(np.sin(ang).astype(np.float32)),
    )


def _mel_weights() -> torch.Tensor:
    """kaldi-native-fbank InitKaldiMelBanks (HTK mel scale, no librosa)."""
    fft_bin_width = 16000.0 / FFT_LEN
    low_freq, high_freq = 20.0, 7600.0      # sherpa: high_freq = -400 -> nyquist - 400
    mel_low = 1127.0 * math.log(1.0 + low_freq / 700.0)
    mel_high = 1127.0 * math.log(1.0 + high_freq / 700.0)
    delta = (mel_high - mel_low) / (NUM_MEL + 1)
    weights = np.zeros((NUM_MEL, NUM_FFT_BINS), dtype=np.float32)
    for b in range(NUM_MEL):
        left = mel_low + b * delta
        center = mel_low + (b + 1) * delta
        right = mel_low + (b + 2) * delta
        for i in range(NUM_FFT_BINS):
            freq = fft_bin_width * i
            mel = 1127.0 * math.log(1.0 + freq / 700.0)
            if mel > left and mel < right:
                if mel <= center:
                    weight = (mel - left) / (center - left)
                else:
                    weight = (right - mel) / (right - center)
                weights[b, i] = weight
    return torch.from_numpy(weights)


class KaldiFbank(nn.Module):
    """Log-mel fbank for a fixed 64000-sample window -> [1, 399, 80]."""

    def __init__(self) -> None:
        super().__init__()
        self.register_buffer("frame_index", _frame_index(), persistent=False)
        self.register_buffer("povey", _povey_window(), persistent=False)
        self.register_buffer("dft_cos", _dft_matrices()[0], persistent=False)
        self.register_buffer("dft_sin", _dft_matrices()[1], persistent=False)
        self.register_buffer("mel_weights", _mel_weights(), persistent=False)

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        # waveform: [1, 64000]
        frames = waveform.reshape(-1)[self.frame_index]           # [399, 400]
        # remove_dc_offset
        frames = frames - frames.mean(dim=-1, keepdim=True)
        # preemph 0.97 (C++: d[i] -= 0.97*d[i-1]; d[0] -= 0.97*d[0])
        pre = torch.cat(
            [frames[..., :1] * (1.0 - 0.97), frames[..., 1:] - 0.97 * frames[..., :-1]],
            dim=-1,
        )
        # povey window, then zero-pad to 512
        windowed = pre * self.povey
        padded = F.pad(windowed, (0, FFT_LEN - FRAME_LEN))
        real = padded @ self.dft_cos.T                           # [399, 257]
        imag = padded @ self.dft_sin.T
        power = real * real + imag * imag                        # [399, 257]
        mel = power[:, :NUM_FFT_BINS] @ self.mel_weights.T       # [399, 80]
        return torch.log(torch.clamp(mel, min=LOG_EPS)).unsqueeze(0)  # [1,399,80]


def _valid_frame_count(num_samples: torch.Tensor) -> torch.Tensor:
    """count(L) for sherpa's unflushed snip_edges=false path."""
    return torch.clamp(torch.floor((num_samples - 280.0) / 160.0) + 1.0, min=0.0, max=float(NUM_FRAMES))


def _downsample_count(count: torch.Tensor) -> torch.Tensor:
    """Valid conv-T positions after the backbone.

    FCM/BasicResBlock stride only the frequency axis (stride=(s,1)); the
    single T downsampling is xvector.tdnn (conv1d k5 stride2), i.e.
    out = floor((in-1)/2)+1.
    """
    count = torch.floor((count - 1.0) / 2.0) + 1.0
    return torch.clamp(count, min=1.0)


_CAM_LAYER_CLASS = None


def _ensure_cam_patch():
    """Patch CAMLayer.forward for masked operation (called once at init).

    CAMLayer pools over T in two places that a fixed-length graph would
    otherwise evaluate over the padded window instead of the valid region:
      context = x.mean(-1) + seg_pooling(x)
    The patched forward zeroes the invalid region at entry (so the k3
    local conv and the seg average see exactly what the shorter reference
    graph sees) and replaces the mean with a masked mean.
    """
    global _CAM_LAYER_CLASS
    if _CAM_LAYER_CLASS is None:
        sys.path.insert(0, str(HERE / "thirdparty"))
        from speakerlab.models.campplus.layers import CAMLayer

        original_forward = CAMLayer.forward

        def masked_forward(self, x):
            mask = self.__dict__.get("_valid_mask")
            if mask is None:
                return original_forward(self, x)
            x = x * mask
            y = self.linear_local(x)
            n = mask.sum(dim=-1, keepdim=True).clamp(min=1.0)
            context = (x * mask).sum(dim=-1, keepdim=True) / n + self.seg_pooling(x)
            context = self.relu(self.linear1(context))
            m = self.sigmoid(self.linear2(context))
            return y * m

        CAMLayer.forward = masked_forward
        _CAM_LAYER_CLASS = CAMLayer
    return _CAM_LAYER_CLASS


def build_campplus(checkpoint: Path) -> nn.Module:
    sys.path.insert(0, str(HERE / "thirdparty"))
    from speakerlab.models.campplus.DTDNN import CAMPPlus

    model = CAMPPlus(
        feat_dim=80,
        embedding_size=192,
        growth_rate=32,
        bn_size=4,
        init_channels=128,
        config_str="batchnorm-relu",
        memory_efficient=True,
    )
    sd = torch.load(str(checkpoint), map_location="cpu", weights_only=True)
    missing, unexpected = model.load_state_dict(sd, strict=False)
    if missing or unexpected:
        raise RuntimeError(f"checkpoint mismatch missing={missing[:3]} unexpected={unexpected[:3]}")
    model.eval()
    return model


class SpeakerWaveWrapper(nn.Module):
    """waveform [1,64000] + numSamples [1,1] -> embedding [1,192].

    masked=True (default): CMN over valid frames only, invalid rows zeroed,
    statistics pooling masked to the reference graph's conv-T length.
    masked=False: naive full-window pooling (the report's pad-to-4s plan);
    kept only as the A/B baseline in verify_wave_wrapper.py.
    """

    def __init__(self, checkpoint: Path, masked: bool = True) -> None:
        super().__init__()
        base = build_campplus(checkpoint)
        self.head = base.head
        kept = [(n, m) for n, m in base.xvector.named_children() if n not in ("stats", "dense")]
        self.backbone = nn.Sequential(OrderedDict(kept))
        self.dense = base.xvector.dense
        self.fbank = KaldiFbank()
        self.masked = masked
        self._cam_cls = _ensure_cam_patch() if masked else None
        self.register_buffer("rows_frames", torch.arange(NUM_FRAMES, dtype=torch.float32).reshape(1, NUM_FRAMES, 1), persistent=False)
        # frame-depth region (head input/output keep T=399) and conv-depth
        # region (after the single tdnn stride2, T=200)
        self.register_buffer("rows_t399", torch.arange(NUM_FRAMES, dtype=torch.float32).reshape(1, 1, NUM_FRAMES), persistent=False)
        self.register_buffer("rows_conv", torch.arange(200, dtype=torch.float32).reshape(1, 1, 200), persistent=False)

    def forward(self, waveform: torch.Tensor, num_samples: torch.Tensor) -> torch.Tensor:
        feats = self.fbank(waveform)                             # [1,399,80]
        count = _valid_frame_count(num_samples)                  # [1,1]
        if self.masked:
            frame_mask = (self.rows_frames < count).to(feats.dtype)   # [1,399,1]
            n_frames = frame_mask.sum(dim=1, keepdim=True).clamp(min=1.0)
            mean = (feats * frame_mask).sum(dim=1, keepdim=True) / n_frames
            feats = (feats - mean) * frame_mask                  # global-mean CMN + zero invalid
            region_399 = (self.rows_t399 < count).to(feats.dtype)               # [1,1,399]
            region_200 = (self.rows_conv < _downsample_count(count)).to(feats.dtype)  # [1,1,200]
        else:
            mean = feats.mean(dim=1, keepdim=True)
            feats = feats - mean
            region_399 = None
            region_200 = None

        x = feats.permute(0, 2, 1)                               # [1,80,399]
        if region_200 is not None:
            for mod in self.modules():
                if isinstance(mod, self._cam_cls):
                    mod.__dict__["_valid_mask"] = region_200
        try:
            h = self.head(x)
            if region_399 is not None:
                h = h * region_399
            for child in self.backbone:
                h = child(h)
                if region_200 is not None:
                    h = h * region_200
        finally:
            if region_200 is not None:
                for mod in self.modules():
                    if isinstance(mod, self._cam_cls):
                        mod.__dict__["_valid_mask"] = None

        if region_200 is not None:
            n_conv = region_200.sum(dim=-1, keepdim=True).clamp(min=1.0)
            mu = (h * region_200).sum(dim=-1, keepdim=True) / n_conv
            var = ((h - mu) * (h - mu) * region_200).sum(dim=-1, keepdim=True) / (n_conv - 1.0).clamp(min=1.0)
            stats = torch.cat([mu, torch.sqrt(var.clamp(min=0.0))], dim=1)
        else:
            mu = h.mean(dim=-1, keepdim=True)
            sigma = h.std(dim=-1, unbiased=True, keepdim=True)
            stats = torch.cat([mu, sigma], dim=1)
        return self.dense(stats).reshape(1, 192)
