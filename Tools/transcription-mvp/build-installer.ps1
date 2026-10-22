param(
    [string]$PackageDir = (Join-Path $PSScriptRoot '../../Releases/Windows/LingoClass'),
    [string]$Compiler = (Join-Path $PSScriptRoot '../../Build/installer-tools/inno/ISCC.exe')
)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageDir).Path
if (!(Test-Path (Join-Path $package '_internal/python312.dll'))) { throw 'Application dependencies missing' }
if (!(Test-Path -LiteralPath $Compiler)) { throw 'Install Inno Setup and pass its ISCC.exe path using -Compiler' }
$output = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Releases/Installers'))
$version = & python -c "import runpy,sys; print(runpy.run_path(sys.argv[1])['VERSION'])" (Join-Path $PSScriptRoot 'app_version.py')
if ($LASTEXITCODE -ne 0 -or !$version) { throw 'Cannot read application version' }
& $Compiler "/DPackageDir=$package" "/DOutputDir=$output" "/DAppVersion=$version" (Join-Path $PSScriptRoot 'LingoClass-installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
