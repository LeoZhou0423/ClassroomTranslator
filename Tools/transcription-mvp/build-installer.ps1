param(
    [string]$PackageDir = (Join-Path $PSScriptRoot '../../Releases/Windows/LingoClass'),
    [string]$Compiler = (Join-Path $PSScriptRoot '../../Build/installer-tools/inno/ISCC.exe')
)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageDir).Path
if (!(Test-Path (Join-Path $package '_internal/python312.dll'))) { throw 'Application dependencies missing' }
if (!(Test-Path -LiteralPath $Compiler)) { throw 'Install Inno Setup and pass its ISCC.exe path using -Compiler' }
$output = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Releases/Installers'))
& $Compiler "/DPackageDir=$package" "/DOutputDir=$output" (Join-Path $PSScriptRoot 'LingoClass-installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
