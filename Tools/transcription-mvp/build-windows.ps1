$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location (Join-Path $projectRoot 'Desktop')
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed' }
} finally { Pop-Location }
Push-Location $PSScriptRoot
try {
    python -c "import keyring,json; from pathlib import Path; key=keyring.get_password('LingoClass','qwen-api-key'); assert key, 'Missing private API configuration'; Path('../../Build').mkdir(exist_ok=True); Path('../../Build/private-config.json').write_text(json.dumps({'qwen_key':key}),encoding='utf-8')"
    if ($LASTEXITCODE -ne 0) { throw 'Private API configuration unavailable' }
    python -m PyInstaller LingoClass.spec --distpath (Join-Path $projectRoot 'Releases/Windows') --workpath (Join-Path $projectRoot 'Build/windows-package') --noconfirm
    if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed' }
} finally { Pop-Location }
& (Join-Path $PSScriptRoot 'build-installer.ps1')
