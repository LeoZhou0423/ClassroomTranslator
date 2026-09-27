#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
cd /root/autodl-tmp
if [ ! -d TalkMoves ]; then
  git clone --depth 1 https://github.com/SumnerLab/TalkMoves.git
fi
echo '=== data files ==='
ls -la TalkMoves/data
echo '=== line counts ==='
wc -l TalkMoves/data/train_teacher.tsv TalkMoves/data/train_student.tsv TalkMoves/data/test_teacher.tsv TalkMoves/data/test_student.tsv || true
echo '=== sample teacher ==='
head -3 TalkMoves/data/train_teacher.tsv
echo '=== sample student ==='
head -3 TalkMoves/data/train_student.tsv
