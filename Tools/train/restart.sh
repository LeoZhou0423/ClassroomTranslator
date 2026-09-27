#!/bin/bash
pkill -f train_role_classifier.py || true
pkill -f run_train.sh || true
sleep 1
nohup bash /root/run_train.sh > /root/train.log 2>&1 &
echo "started_pid=$!"
sleep 2
ps aux | grep -E 'run_train|train_role|convert_xlsx' | grep -v grep || true
tail -20 /root/train.log || true
