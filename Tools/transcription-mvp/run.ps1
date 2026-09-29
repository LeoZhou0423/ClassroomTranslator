$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
py -m pip install -r requirements.txt
py download_models.py
py download_translation_model.py
py app.py
