#!/bin/bash
export PATH=/root/miniconda3/bin:$PATH
echo '=== py stack ==='
pid=$(pgrep -f train_role_classifier.py | head -1)
echo pid=$pid
if [ -n "$pid" ]; then
  echo '--- cwd ---'
  readlink /proc/$pid/cwd
  echo '--- status ---'
  grep -E 'State|Threads|VmRSS' /proc/$pid/status
  echo '--- open files (top) ---'
  ls -l /proc/$pid/fd 2>/dev/null | head -25
fi
echo '=== recent files under autodl-tmp ==='
find /root/autodl-tmp -mmin -30 -type f 2>/dev/null | head -40
echo '=== hf cache ==='
du -sh /root/autodl-tmp/hf_cache 2>/dev/null || echo no_hf_cache
ls /root/autodl-tmp/hf_cache 2>/dev/null | head
echo '=== process start time ==='
ps -o pid,etime,cmd -p $pid 2>/dev/null || true
