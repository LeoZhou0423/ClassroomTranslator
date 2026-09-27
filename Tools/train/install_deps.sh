#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
pip install -q transformers datasets scikit-learn accelerate pandas openpyxl
python -c "import transformers,datasets,sklearn; print('OK', transformers.__version__, datasets.__version__, sklearn.__version__)"
