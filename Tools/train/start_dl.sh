#!/bin/bash
pkill -f train_role_classifier.py || true
pkill -f download_model.sh || true
sleep 1
nohup bash /root/download_model.sh > /root/download.log 2>&1 &
echo started=$!
sleep 3
cat /root/download.log
ls -lh /root/autodl-tmp/minilm 2>/dev/null || true
