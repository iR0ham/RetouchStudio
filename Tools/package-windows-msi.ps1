# Builds the per-machine MSI from a published application folder with WiX
# Toolset v3 (heat, candle, light) and writes a SHA-256 file next to it.
#
#   pwsh -File Tools/package-windows-msi.ps1 -AppDir build/windows/app -Version 1.0.0-ci
#
# The MSI installs to Program Files, adds a Start menu shortcut and upgrades a
# previous version through the fixed UpgradeCode in Windows/installer/Product.wxs.
# The file list is harvested from the publish output, so no file is listed here
# and the installer cannot drift from the build.
#
# The output is unsigned: signing needs a code-signing certificate this project
# does not have, and an unsigned package is what the CI install proof exercises.

param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutputDir = 'dist',
    [string]$Executable = 'RetouchStudio.exe',
    [string]$WixDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
    Write-Error "Version '$Version' has no numeric major.minor.patch prefix"
}
$msiVersion = "$($matches[1]).$($matches[2]).$($matches[3]).0"

$app = (Resolve-Path $AppDir).Path
$exe = Join-Path $app $Executable
if (-not (Test-Path $exe -PathType Leaf)) {
    Write-Error "$Executable was not found in $app"
}

function Find-Wix([string]$requested) {
    $candidates = @($requested, $env:WIX,
        (Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14'),
        (Join-Path $env:ProgramFiles 'WiX Toolset v3.14'),
        (Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.11'),
        (Join-Path $env:ProgramFiles 'WiX Toolset v3.11'))
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path (Join-Path $candidate 'bin\candle.exe')) { return (Resolve-Path $candidate).Path }
    }
    return $null
}

$wix = Find-Wix $WixDir
if (-not $wix) {
    Write-Error 'WiX Toolset v3 was not found; install it, or pass -WixDir / set WIX'
}
$bin = Join-Path $wix 'bin'
$heat = Join-Path $bin 'heat.exe'
$candle = Join-Path $bin 'candle.exe'
$light = Join-Path $bin 'light.exe'

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$output = (Resolve-Path $OutputDir).Path
$name = "RetouchStudio-$Version-windows-x64.msi"
$msi = Join-Path $output $name
if (Test-Path $msi) { Remove-Item $msi -Force }

$obj = Join-Path $env:TEMP ("retouchstudio-msi-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $obj | Out-Null
try {
    $files = Join-Path $obj 'AppFiles.wxs'
    & $heat dir $app -cg AppFiles -gg -srd -sreg -scom -dr INSTALLFOLDER -var var.AppDir -out $files
    if ($LASTEXITCODE -ne 0) { Write-Error "heat failed with exit code $LASTEXITCODE" }

    $sources = @(
        (Join-Path $root 'Windows/installer/Product.wxs'),
        $files
    )
    $defines = @(('-dAppDir=' + $app), ('-dProductVersion=' + $msiVersion))
    Write-Host "   candle $($defines -join ' ')"
    & $candle -nologo -arch x64 $defines -out (Join-Path $obj '') $sources
    if ($LASTEXITCODE -ne 0) { Write-Error "candle failed with exit code $LASTEXITCODE" }

    $objects = Get-ChildItem -Path $obj -Filter '*.wixobj' | ForEach-Object { $_.FullName }
    & $light -nologo -out $msi $objects
    if ($LASTEXITCODE -ne 0) { Write-Error "light failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path $msi -PathType Leaf)) { Write-Error "light did not write $msi" }

    $hash = (Get-FileHash -Path $msi -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = "$msi.sha256"
    $line = $hash + '  ' + $name + "`n"
    [System.IO.File]::WriteAllText($manifest, $line, [System.Text.UTF8Encoding]::new($false))

    $size = (Get-Item $msi).Length
    Write-Host "built $name ($size bytes, msi version $msiVersion)"
    Write-Host "sha256 $hash"
}
finally {
    if (Test-Path $obj) { Remove-Item $obj -Recurse -Force -ErrorAction SilentlyContinue }
}
