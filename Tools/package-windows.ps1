# Packages a built Windows application directory into one x64 zip and writes a
# SHA-256 file next to it. Intel and AMD both run the same x64 build; this
# script never produces a vendor-specific artifact.
#
#   pwsh -File Tools/package-windows.ps1 -AppDir build/windows -Version 1.0.0
#
# The output is unsigned. Publishing an unsigned binary is free and is the
# documented default; no paid certificate or notarization is involved.
#
# Verified on Windows: CI run 43537354813 (2026-11-14, head 6882246) built
# RetouchStudio-0.0.0-ci-windows-x64.zip, matched its SHA-256 manifest and
# started the extracted app to a loaded window.

param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutputDir = 'dist',
    [string]$Executable = 'RetouchStudio.exe'
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    Write-Error "Version '$Version' is not a semantic version"
}

$app = (Resolve-Path $AppDir).Path
$exe = Join-Path $app $Executable
if (-not (Test-Path $exe -PathType Leaf)) {
    Write-Error "$Executable was not found in $app"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$name = "RetouchStudio-$Version-windows-x64.zip"
$zip = Join-Path (Resolve-Path $OutputDir).Path $name
if (Test-Path $zip) { Remove-Item $zip -Force }

Compress-Archive -Path (Join-Path $app '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = "$zip.sha256"
$line = $hash + '  ' + $name + "`n"
[System.IO.File]::WriteAllText($manifest, $line, [System.Text.UTF8Encoding]::new($false))

$size = (Get-Item $zip).Length
Write-Host "built $name ($size bytes)"
Write-Host "sha256 $hash"
