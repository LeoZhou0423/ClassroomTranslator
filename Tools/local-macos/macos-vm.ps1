[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'status', 'logs', 'open')]
    [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'
$ComposeFile = Join-Path $PSScriptRoot 'compose.yml'
$ViewerUrl = 'http://127.0.0.1:8006'

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & docker compose --file $ComposeFile @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE"
    }
}

switch ($Action) {
    'start' {
        Invoke-Compose up --detach
        # The Compose entrypoint arms the microphone bridge before QEMU starts.
        Write-Host "macOS VM is starting. Open $ViewerUrl to install or use it."
        Start-Process $ViewerUrl
    }
    'stop' {
        Invoke-Compose stop
    }
    'status' {
        Invoke-Compose ps
    }
    'logs' {
        Invoke-Compose logs --follow --tail 100
    }
    'open' {
        Start-Process $ViewerUrl
    }
}
