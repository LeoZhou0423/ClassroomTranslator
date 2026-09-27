#!/bin/bash
export PATH=/root/miniconda3/bin:$PATH
cd /root/autodl-tmp/TalkMoves
echo '=== teacher tsv cols ==='
head -1 data/train_teacher.tsv | od -c | head
echo '=== more teacher rows ==='
sed -n '2,8p' data/train_teacher.tsv
echo '=== student rows ==='
sed -n '2,8p' data/train_student.tsv
echo '=== Subset1 sample ==='
ls "data/Subset 1" | head
python - <<'PY'
from pathlib import Path
import openpyxl
p = Path('data/test_data_63.xlsx')
wb = openpyxl.load_workbook(p, read_only=True, data_only=True)
print('sheets', wb.sheetnames)
ws = wb[wb.sheetnames[0]]
rows = []
for i, row in enumerate(ws.iter_rows(values_only=True)):
    rows.append(row)
    if i >= 8:
        break
for r in rows:
    print(r)
print('max_col', ws.max_column, 'max_row', ws.max_row)
# header
header = rows[0] if rows else []
print('header', header)
PY
