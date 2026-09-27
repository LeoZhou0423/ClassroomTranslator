#!/bin/bash
export PATH=/root/miniconda3/bin:$PATH
echo '=== processes ==='
ps aux | grep -E 'train_role|run_train' | grep -v grep || echo none
echo '=== role-cls ==='
ls -la /root/autodl-tmp/role-cls 2>/dev/null || echo 'no role-cls'
echo '=== checkpoints ==='
ls -la /root/autodl-tmp/role-cls/checkpoints 2>/dev/null || echo 'no checkpoints'
echo '=== final ==='
ls -la /root/autodl-tmp/role-cls/final 2>/dev/null || echo 'no final'
echo '=== report ==='
cat /root/autodl-tmp/role-cls/test_report.txt 2>/dev/null || echo 'no report'
echo '=== metrics ==='
cat /root/autodl-tmp/role-cls/test_metrics.json 2>/dev/null || echo 'no metrics'
echo '=== stats ==='
cat /root/autodl-tmp/role-cls/data_stats.json 2>/dev/null || echo 'no stats'
echo '=== nvidia ==='
nvidia-smi | head -15
