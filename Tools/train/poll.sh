#!/bin/bash
echo '=== minilm ==='
ls -lh /root/autodl-tmp/minilm 2>/dev/null || echo none
echo '=== procs ==='
ps aux | grep -E 'download_model|curl|train_role|run_train' | grep -v grep || echo none
echo '=== train.log ==='
tail -15 /root/train.log
