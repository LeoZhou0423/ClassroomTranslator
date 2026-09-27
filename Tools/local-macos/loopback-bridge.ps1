[CmdletBinding()]
param(
    [string]$Device = '',
    [double]$Gain = 1.5,
    [string]$Container = 'classroomtranslator-macos',
    [string]$Python = ''
)
# Stream Windows *system playback* (WASAPI loopback) into the macOS VM mic.
# Use when you want the VM to hear what this PC is playing (video, slides audio).

$ErrorActionPreference = 'Stop'
if (-not $Python) {
    $Python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $Python) { $Python = 'python' }
}
$script = Join-Path $PSScriptRoot 'loopback-bridge.py'
Write-Output ('python: ' + $Python)
Write-Output ('loopback bridge: ' + $script)
$argsList = @($script, '--gain', $Gain.ToString([Globalization.CultureInfo]::InvariantCulture), '--container', $Container)
if ($Device) { $argsList += @('--device', $Device) }
& $Python @argsList
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
