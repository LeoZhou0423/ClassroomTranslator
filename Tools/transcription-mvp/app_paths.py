"""Separate immutable packaged resources from writable user recordings."""
import os
import sys
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent
FROZEN = getattr(sys, 'frozen', False)
BUNDLE_ROOT = Path(sys._MEIPASS) if FROZEN else SOURCE_ROOT.parent.parent
MODEL_ROOT = BUNDLE_ROOT / 'models' if FROZEN else SOURCE_ROOT / 'models'
WEB_ROOT = BUNDLE_ROOT / 'Desktop' / 'dist'
ICON_PATH = BUNDLE_ROOT / 'Desktop' / 'public' / 'app-icon.ico'
DATA_ROOT = Path(os.getenv('LOCALAPPDATA', str(Path.home()))) / 'LingoClass' if FROZEN else SOURCE_ROOT
if FROZEN and sys.platform=='darwin':
    DATA_ROOT=Path.home()/'Library'/'Application Support'/'LingoClass'

def speech_model_dir(name):
    downloaded=DATA_ROOT/'models'/f'whisper-{name}'
    required=[f'{name}-encoder.int8.onnx',f'{name}-decoder.int8.onnx',f'{name}-tokens.txt','silero_vad.int8.onnx']
    return downloaded if all((downloaded/f).is_file() for f in required) else MODEL_ROOT/f'whisper-{name}'
