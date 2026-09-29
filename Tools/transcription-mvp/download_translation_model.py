from pathlib import Path

from huggingface_hub import snapshot_download

ROOT = Path(__file__).resolve().parent
TARGET = ROOT / "models" / "opus-mt-en-zh-ct2"

if __name__ == "__main__":
    TARGET.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id="ooeoeo/opus-mt-en-zh-ct2-float16",
        local_dir=TARGET,
        allow_patterns=[
            "config.json", "model.bin", "shared_vocabulary.json",
            "source.spm", "target.spm", "tokenizer_config.json", "vocab.json",
        ],
    )
    print(f"翻译模型已就绪：{TARGET}")
