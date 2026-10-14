$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location (Join-Path $projectRoot 'Desktop')
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed' }
} finally { Pop-Location }
Push-Location $PSScriptRoot
try {
    # The previous build read the Qwen key out of the Windows credential store and wrote it
    # verbatim into Build/private-config.json, which PyInstaller then packed into the
    # installer -- publishing a live key with every release. Credentials now ship as
    # secrets/keys.enc.json (AES-256-GCM; the passphrase is split across secrets_shares.py),
    # and LingoClass.spec refuses to build without it.
    $sealed = Join-Path $PSScriptRoot 'secrets/keys.enc.json'
    if (!(Test-Path -LiteralPath $sealed)) {
        throw 'secrets/keys.enc.json is missing. Run: python encrypt_secrets.py --bigmodel <key> --mimo <key>'
    }
    python -m PyInstaller LingoClass.spec --distpath (Join-Path $projectRoot 'Releases/Windows') --workpath (Join-Path $projectRoot 'Build/windows-package') --noconfirm
    if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed' }
    # Fail the build if a live key leaked into the packaged tree.
    $package = Join-Path $projectRoot 'Releases/Windows/LingoClass'
    $leaked = Get-ChildItem -Path $package -Recurse -File -Include *.json,*.py,*.txt -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\secrets\*' } |
        ForEach-Object { Select-String -Path $_.FullName -Pattern 'sk-[A-Za-z0-9]{16,}' -ErrorAction SilentlyContinue }
    if ($leaked) { throw ('A plaintext API key was found in the package: ' + $leaked[0].Path) }
} finally { Pop-Location }
& (Join-Path $PSScriptRoot 'build-installer.ps1')
