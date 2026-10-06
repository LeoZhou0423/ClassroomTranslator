import argparse
from pathlib import Path
from download_file import download_file

ROOT = Path(__file__).resolve().parent


def fetch(model_dir: Path, name: str, url: str) -> None:
    target = model_dir / name
    if target.exists() and target.stat().st_size > 100_000:
        print(f"已有 {name} ({target.stat().st_size / 1e6:.1f} MB)")
        return
    download_file(url, target, lambda copied,total,retry: print(f"\r{name}: {copied * 100 // total}%" if total else f"\r{name}: 重试 {retry}，已保留 {copied} 字节", end="", flush=True))
    print(f"\r完成 {name} ({target.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=("tiny", "base", "small", "small.en"), default="small")
    args = parser.parse_args()
    model_dir = ROOT / "models" / f"whisper-{args.model}"
    model_dir.mkdir(parents=True, exist_ok=True)
    base = f"https://huggingface.co/csukuangfj/sherpa-onnx-whisper-{args.model}/resolve/main"
    files = {
        f"{args.model}-encoder.int8.onnx": f"{base}/{args.model}-encoder.int8.onnx?download=true",
        f"{args.model}-decoder.int8.onnx": f"{base}/{args.model}-decoder.int8.onnx?download=true",
        f"{args.model}-tokens.txt": f"{base}/{args.model}-tokens.txt?download=true",
        "silero_vad.int8.onnx": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx",
    }
    for filename, source in files.items():
        fetch(model_dir, filename, source)
