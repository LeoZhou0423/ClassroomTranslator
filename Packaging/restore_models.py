"""Restore byte-identical trained models; never commit private configuration."""
from pathlib import Path
import hashlib
import json

root=Path(__file__).resolve().parent.parent
assets=root/'Packaging'/'models'
for item in json.loads((assets/'manifest.json').read_text()):
    target=root/item['destination']
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('wb') as out:
        for part in item['parts']:
            out.write((assets/part).read_bytes())
    assert hashlib.sha256(target.read_bytes()).hexdigest()==item['sha256'],target
