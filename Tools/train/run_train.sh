#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
export HF_HOME=/root/autodl-tmp/hf_cache
export TRANSFORMERS_CACHE=/root/autodl-tmp/hf_cache
export TOKENIZERS_PARALLELISM=false
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

echo '[1/2] train MiniLM 2-class'
python /root/train_role_classifier.py \
  --data-dir /root/autodl-tmp/talkmoves_jsonl \
  --output /root/autodl-tmp/role-cls \
  --model /root/autodl-tmp/minilm \
  --epochs 3 \
  --batch-size 64 \
  --lr 2e-5 \
  --max-length 128

echo '[2/2] report'
ls -la /root/autodl-tmp/role-cls/final
cat /root/autodl-tmp/role-cls/test_report.txt
