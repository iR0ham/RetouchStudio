# Builds StudioCore with a native Windows Swift toolchain, proves the module is
# still Foundation-only, then runs Tests/StudioCoreTests.swift linked against
# the module alone. This is the executable form of the Windows portability
# claim for the shared core. It does not build the macOS app, and it is not
# evidence for any Windows renderer, UI or packaging behaviour — those do not
# exist yet.
#
#   pwsh -File Tests/run-studiocore-windows.ps1
#
# Requires a Swift toolchain for Windows on PATH (swiftc.exe). The script was
# written against the swift.org Windows toolchain layout; it has not been run
# on a Windows host from this repository yet.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    Write-Host 'swiftc is not on PATH; install a Swift toolchain for Windows' -ForegroundColor Red
    exit 1
}

$forbiddenImports = 'AppKit|SwiftUI|CoreImage|Vision|ImageIO|CoreGraphics|UIKit|UniformTypeIdentifiers|CoreVideo|Metal|AVFoundation|Cocoa|RetouchStudio'
$platformTypes = 'NSColor|NSImage|NSFont|NSBezierPath|CIImage|CIColor|CIFilter|CGImage|CGColor|CGContext|CGRect|CGSize|CGPoint|CGFloat|CGAffineTransform|VNDetect[A-Za-z]*|VNImageRequestHandler|VNRecognize[A-Za-z]*|UTType|\bColor\b|\bImage\b|\bView\b'

$failed = $false
function Fail([string]$Message) {
    Write-Host "  x $Message" -ForegroundColor Red
    $script:failed = $true
}

Write-Host '-> scanning Sources/StudioCore for platform dependencies'
$importSet = @{}
Get-ChildItem Sources/StudioCore -Filter *.swift | ForEach-Object {
    $lines = Get-Content $_.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $code = $lines[$i] -replace '//.*$', ''
        if ($code -match "^\s*(@[^\s]+\s+)*import\s+") {
            $importSet[$code.Trim()] = $true
            if ($code -match "^\s*(@[^\s]+\s+)*import\s+($forbiddenImports)\b") {
                Fail "$($_.Name):$($i + 1) imports a platform/app module: $code"
            }
        }
        if ($code -match $platformTypes) {
            Fail "$($_.Name):$($i + 1) mentions a platform type: $code"
        }
    }
}

$imports = @($importSet.Keys | Sort-Object)
if ($imports.Count -ne 1 -or $imports[0] -ne 'import Foundation') {
    Fail "StudioCore imports more than Foundation: $($imports -join ', ')"
}
if ($failed) {
    Write-Host '  x the boundary failed; not compiling' -ForegroundColor Red
    exit 1
}
Write-Host '  ok Foundation only; no platform type in the module'

$coreDir = 'build/studiocore/windows'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("studiocore-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $coreDir | Out-Null
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$cacheDir = Join-Path $workDir 'cache'

try {
    Write-Host "-> building StudioCore on $([System.Environment]::OSVersion.VersionString)"
    $sources = @(Get-ChildItem Sources/StudioCore -Filter *.swift | ForEach-Object { $_.FullName })
    & swiftc -O -module-name StudioCore `
        -module-cache-path $cacheDir `
        -emit-module -emit-module-path (Join-Path $coreDir 'StudioCore.swiftmodule') `
        -emit-library -static -o (Join-Path $coreDir 'StudioCore.lib') `
        $sources
    if ($LASTEXITCODE -ne 0) { throw "StudioCore compilation failed ($LASTEXITCODE)" }

    Copy-Item Tests/StudioCoreTests.swift (Join-Path $workDir 'main.swift')
    Write-Host '-> compiling the tests against Foundation and StudioCore only'
    $testExe = Join-Path $workDir 'StudioCoreTests.exe'
    & swiftc -O -module-cache-path $cacheDir -I $coreDir `
        -o $testExe (Join-Path $workDir 'main.swift') (Join-Path $coreDir 'StudioCore.lib')
    if ($LASTEXITCODE -ne 0) { throw "test compilation failed ($LASTEXITCODE)" }

    # A Windows static library has no framework list to inspect; the boundary
    # scan above is the portable proof. dumpbin is reported when available so
    # an accidental DLL dependency is visible in the log.
    if (Get-Command dumpbin -ErrorAction SilentlyContinue) {
        Write-Host '-> imported DLLs of the test binary'
        & dumpbin /dependents $testExe
    }

    Write-Host '-> running the StudioCore tests'
    $env:STUDIOCORE_ROOT = (Get-Location).Path
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "StudioCore tests failed ($LASTEXITCODE)" }
}
finally {
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    Remove-Item Env:STUDIOCORE_ROOT -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
Write-Host 'StudioCore Windows portability check: PASS'
