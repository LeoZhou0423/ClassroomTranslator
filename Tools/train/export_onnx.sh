#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
ls -la /root/autodl-tmp/role-cls/final
python - <<'PY'
from pathlib import Path
import torch
from transformers import BertConfig, BertForSequenceClassification, BertTokenizerFast

src = Path('/root/autodl-tmp/role-cls/final')
dst = Path('/root/autodl-tmp/role-cls-onnx')
dst.mkdir(parents=True, exist_ok=True)

print('files', list(src.iterdir()))
config = BertConfig.from_json_file(str(src / 'config.json'))
print('arch', config.architectures if hasattr(config, 'architectures') else None, 'num_labels', config.num_labels)
model = BertForSequenceClassification.from_pretrained(str(src / 'model.safetensors'), config=config, local_files_only=True)
model.eval()
tok = BertTokenizerFast.from_pretrained(str(src), local_files_only=True)

class Wrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, input_ids, attention_mask, token_type_ids):
        out = self.m(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)
        return out.logits

batch = tok(['hello classroom'], return_tensors='pt', padding='max_length', truncation=True, max_length=128)
print('export onnx...')
torch.onnx.export(
    Wrap(model),
    (batch['input_ids'], batch['attention_mask'], batch['token_type_ids']),
    str(dst / 'model.onnx'),
    input_names=['input_ids', 'attention_mask', 'token_type_ids'],
    output_names=['logits'],
    dynamic_axes={
        'input_ids': {0: 'batch', 1: 'seq'},
        'attention_mask': {0: 'batch', 1: 'seq'},
        'token_type_ids': {0: 'batch', 1: 'seq'},
        'logits': {0: 'batch'},
    },
    opset_version=17,
)
tok.save_pretrained(str(dst))
for p in sorted(dst.iterdir()):
    print(p.name, p.stat().st_size)
print('OK')
PY
