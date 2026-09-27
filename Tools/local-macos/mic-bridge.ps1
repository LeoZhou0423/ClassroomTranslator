[CmdletBinding()]
param(
    [string]$Device = '',
    [string]$Ffmpeg = '',
    [double]$Gain = 3.0,
    [string]$Container = 'classroomtranslator-macos'
)

$ErrorActionPreference = 'Stop'
$bundledFfmpeg = Join-Path $PSScriptRoot 'tools\ffmpeg\bin\ffmpeg.exe'

function Find-Ffmpeg {
    if ($Ffmpeg -and (Test-Path -LiteralPath $Ffmpeg)) { return $Ffmpeg }
    $command = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (Test-Path -LiteralPath $bundledFfmpeg) { return $bundledFfmpeg }
    Write-Host 'Downloading ffmpeg (first run only)...'
    $archive = Join-Path $env:TEMP 'ffmpeg-essentials.zip'
    $extractDir = Join-Path $env:TEMP 'classroomtranslator-ffmpeg'
    & curl.exe -fL --retry 3 -o $archive 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive)) { throw 'Failed to download ffmpeg.' }
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
    $downloaded = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $downloaded) { throw 'Failed to extract ffmpeg.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $bundledFfmpeg) | Out-Null
    Copy-Item -LiteralPath $downloaded.FullName -Destination $bundledFfmpeg -Force
    return $bundledFfmpeg
}

$ff = Find-Ffmpeg
Write-Output ('ffmpeg: ' + $ff)

if (-not $Device) {
    $listCommand = '""' + $ff + '" -hide_banner -list_devices true -f dshow -i dummy 2>&1"'
    $deviceList = (& cmd.exe /d /s /c $listCommand | Out-String -Width 4096)
    $audioDevice = [regex]::Match($deviceList, '(?s)"[^"]+"\s+\(audio\).*?Alternative name "([^"]+)"')
    if (-not $audioDevice.Success) { throw ('No DirectShow audio input was found.' + [Environment]::NewLine + $deviceList) }
    $Device = $audioDevice.Groups[1].Value
    Write-Output ('Microphone: ' + $Device)
}

$destination = 'PulseAudio in Docker container ' + $Container
Write-Output ('Streaming to ' + $destination)
while ($true) {
    # DirectShow laptop microphones commonly expose two quiet channels. Mix them
    # to mono, raise speech by about 9.5 dB, then limit peaks before transport.
    $audioFilter = 'pan=mono|c0=0.5*c0+0.5*c1,volume=' + $Gain.ToString([Globalization.CultureInfo]::InvariantCulture) + ',alimiter=limit=0.95'
    # Use a native cmd.exe binary pipe. Windows PowerShell 5 converts native
    # pipeline bytes to text, while Docker Desktop's published TCP port can
    # reset long-lived streams. docker exec -i avoids both failure modes.
    $ffQuoted = '"' + $ff + '"'
    $deviceQuoted = '"audio=' + $Device + '"'
    $filterQuoted = '"' + $audioFilter + '"'
    $containerQuoted = '"' + $Container + '"'
    $pipeCommand = $ffQuoted + ' -hide_banner -loglevel warning -f dshow -i ' + $deviceQuoted +
        ' -af ' + $filterQuoted + ' -ac 1 -ar 48000 -f s16le - | docker exec -i ' +
        $containerQuoted + ' pacat --server=unix:/run/pulse/native --playback --device=mic_sink' +
        ' --raw --format=s16le --rate=48000 --channels=1'
    & cmd.exe /d /s /c $pipeCommand
    Write-Output ((Get-Date -Format 'HH:mm:ss') + ' disconnected; retrying in 2 seconds')
    Start-Sleep -Seconds 2
}
