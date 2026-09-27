#!/bin/bash
pkill -f train_role_classifier.py || true
pkill -f run_train.sh || true
sleep 1
nohup bash /root/run_train.sh > /root/train.log 2>&1 &
echo started=$!
sleep 10
tail -40 /root/train.log
ps aux | grep train_role | grep -v grep || true
