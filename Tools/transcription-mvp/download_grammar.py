"""Download the optional grammar model from its publisher's repository."""
from pathlib import Path
import requests

root = Path(__file__).resolve().parent / 'models' / 'grammar-t5'
root.mkdir(parents=True, exist_ok=True)
for name in ('config.json', 'special_tokens_map.json', 'spiece.model', 'tokenizer.json', 'tokenizer_config.json', 'pytorch_model.bin'):
    if name == 'pytorch_model.bin' and (root / 'model.safetensors').exists(): continue
    target = root / name
    if target.exists(): continue
    response = requests.get('https://huggingface.co/vennify/t5-base-grammar-correction/resolve/main/' + name, stream=True, timeout=(20, 90))
    response.raise_for_status()
    temporary = target.with_suffix(target.suffix + '.part')
    count = 0
    with temporary.open('wb') as output:
        for block in response.iter_content(1024*1024):
            output.write(block)
            count += len(block)
            if count % (50*1024*1024) < len(block): print(f'{name}: {count//1024//1024} MB', flush=True)
    temporary.replace(target)
    print(name + ' ready', flush=True)
