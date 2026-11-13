# Builds StudioCore with a native Windows Swift toolchain, proves the module is
# still Foundation-only, runs Tests/StudioCoreTests.swift linked against the
# module alone, then builds the StudioCore C ABI v0 library and runs the C test
# that links it. This is the executable form of the Windows portability claim
# for the shared core. It does not build the macOS app, and it is not evidence
# for any Windows renderer, UI or packaging behaviour — those do not exist yet.
#
#   pwsh -File Tests/run-studiocore-windows.ps1
#
# Requires a Swift toolchain for Windows on PATH (swiftc.exe) and the clang.exe
# that ships with it. The script was written against the swift.org Windows
# toolchain layout; it has not been run on a Windows host from this repository
# yet, so its pass line is NOT VERIFIED.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    Write-Host 'swiftc is not on PATH; install a Swift toolchain for Windows' -ForegroundColor Red
    exit 1
}

# Git for Windows ships a coreutils `link.exe` in usr\bin, and the hosted
# runner PATH can reach it before MSVC's linker, which the Swift driver calls
# as plain `link`. Put the real VC tools directory first.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($vsPath) {
        $linker = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC\*\bin\Hostx64\x64\link.exe') `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($linker) {
            $env:PATH = $linker.Directory.FullName + ';' + $env:PATH
            Write-Host "-> using the MSVC linker at $($linker.FullName)"
        }
    }
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
        # -cmatch, not -match: PowerShell matching is case-insensitive by
        # default, which would make \bColor\b hit the lowercase `.color`
        # property and diverge from the `grep -E` gate on macOS.
        if ($code -cmatch "^\s*(@[^\s]+\s+)*import\s+") {
            $importSet[$code.Trim()] = $true
            if ($code -cmatch "^\s*(@[^\s]+\s+)*import\s+($forbiddenImports)\b") {
                Fail "$($_.Name):$($i + 1) imports a platform/app module: $code"
            }
        }
        if ($code -cmatch $platformTypes) {
            Fail "$($_.Name):$($i + 1) mentions a platform type: $code"
        }
    }
}

$imports = @($importSet.Keys | Sort-Object)
if ($imports.Count -ne 1 -or $imports[0] -cne 'import Foundation') {
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

    # The same C ABI library and C test as macOS. clang.exe ships with the
    # Swift toolchain, so the C side compiles with the same compiler family.
    $clang = Get-Command clang -ErrorAction SilentlyContinue
    if (-not $clang) { throw 'clang is not on PATH; it ships with the Swift toolchain' }

    Write-Host '-> building the StudioCore C ABI library'
    $abiDir = 'build/studioabi/windows'
    New-Item -ItemType Directory -Force -Path $abiDir | Out-Null
    $abiSources = @(Get-ChildItem Sources/StudioCoreABI -Filter *.swift |
        ForEach-Object { $_.FullName })
    & swiftc -O -module-name StudioCoreABI -module-cache-path $cacheDir `
        -emit-module -emit-module-path (Join-Path $abiDir 'StudioCoreABI.swiftmodule') `
        -emit-library -static -o (Join-Path $abiDir 'StudioCoreABI.lib') `
        -I $coreDir $abiSources
    if ($LASTEXITCODE -ne 0) { throw "StudioCoreABI compilation failed ($LASTEXITCODE)" }

    Write-Host '-> compiling the C11 ABI test against the public header'
    $object = Join-Path $workDir 'abi_tests.obj'
    # The MSVC CRT marks getenv/fopen deprecated; the test is portable C11 and
    # is compiled with -Werror, so silence only that CRT warning.
    & clang -std=c11 -Wall -Wextra -Werror -pedantic `
        -D_CRT_SECURE_NO_WARNINGS `
        -I Sources/StudioCoreABI/include `
        -c Tests/ABI/abi_tests.c -o $object
    if ($LASTEXITCODE -ne 0) { throw "C ABI test compilation failed ($LASTEXITCODE)" }

    Write-Host '-> linking the C test with the Swift libraries'
    $abiExe = Join-Path $workDir 'abi_tests.exe'
    & swiftc -O -module-cache-path $cacheDir -o $abiExe `
        $object `
        (Join-Path $abiDir 'StudioCoreABI.lib') (Join-Path $coreDir 'StudioCore.lib')
    if ($LASTEXITCODE -ne 0) { throw "C ABI test link failed ($LASTEXITCODE)" }

    Write-Host '-> running the C ABI tests'
    & $abiExe
    if ($LASTEXITCODE -ne 0) { throw "C ABI tests failed ($LASTEXITCODE)" }
}
finally {
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    Remove-Item Env:STUDIOCORE_ROOT -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
Write-Host 'StudioCore Windows portability check: PASS'
