#!/bin/bash
export PATH=/root/miniconda3/bin:$PATH
echo '=== hf cache size ==='
du -sh /root/autodl-tmp/hf_cache 2>/dev/null || echo no_cache
find /root/autodl-tmp/hf_cache -type f 2>/dev/null | head -20
echo '=== env of train proc ==='
pid=$(pgrep -f train_role_classifier.py | head -1)
echo pid=$pid
tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep -E 'HF_|TRANSFORMERS|http' || true
echo '=== network test hf-mirror ==='
curl -sI --max-time 10 https://hf-mirror.com | head -5
echo '=== network test huggingface.co ==='
curl -sI --max-time 10 https://huggingface.co | head -5
echo '=== strace-ish: open files ==='
ls -l /proc/$pid/fd 2>/dev/null | head -20
echo '=== wchan ==='
cat /proc/$pid/wchan 2>/dev/null; echo
echo '=== log tail ==='
tail -5 /root/train.log
