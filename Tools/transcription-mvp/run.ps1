param([ValidateSet('tiny','base','small','small.en')][string]$Model='small',[int]$Port=8785)
$ErrorActionPreference='Stop'
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$env:PYTHONUTF8='1'
try {
    $taskExisting=Invoke-RestMethod "http://127.0.0.1:$Port/api/state" -TimeoutSec 2
    if($taskExisting.version -eq '20261005-caption-realtime-4') {
        Start-Process "http://127.0.0.1:$Port"
        return
    }
} catch {}
python -m pip install -r requirements-asr.txt
if($LASTEXITCODE -ne 0){throw '依赖安装失败'}
python download_models.py --model $Model
if($LASTEXITCODE -ne 0){throw '模型下载失败'}
python asr_lab.py --port $Port --open-browser
