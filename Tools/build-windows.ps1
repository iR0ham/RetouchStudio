# Builds the Windows host end to end on a native Windows machine: the StudioCore
# C ABI as studioscore_core.dll, a self-contained x64 publish of the WPF app,
# the headless host tests against the real DLL and Windows Imaging Component,
# and a GUI liveness check that the published exe opens a window.
#
#   pwsh -File Tools/build-windows.ps1
#   pwsh -File Tools/build-windows.ps1 -SkipGuiSmoke     # no interactive desktop
#
# Requires a Swift toolchain for Windows (swiftc.exe plus its clang.exe and lld)
# and the .NET 10 SDK, both on PATH. Intel and AMD machines run the same x64
# build; there is no vendor-specific artifact.

param(
    [string]$Configuration = 'Release',
    [switch]$SkipTests,
    [switch]$SkipGuiSmoke,
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

function Step([string]$Message) {
    Write-Host "-> $Message"
}

function Assert-ExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed ($LASTEXITCODE)"
    }
}

if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    throw 'swiftc is not on PATH; install a Swift toolchain for Windows'
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet is not on PATH; install the .NET SDK'
}

# Git for Windows ships a coreutils link.exe in usr\bin, and the hosted runner
# PATH can reach it before MSVC's linker. Put the real VC tools directory first.
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
            Write-Host "   using the MSVC linker at $($linker.FullName)"
        }
    }
}

$nativeDir = Join-Path $root 'build/windows/native'
$appDir = Join-Path $root 'build/windows/app'
$cacheDir = Join-Path $root 'build/windows/swift-cache'
New-Item -ItemType Directory -Force -Path $nativeDir, $cacheDir | Out-Null

# 1. StudioCore as a static library, the same module the macOS app and the
#    Windows core job compile.
Step 'building StudioCore'
$coreSources = @(Get-ChildItem Sources/StudioCore -Filter *.swift |
    ForEach-Object { $_.FullName })
& swiftc -O -module-name StudioCore -module-cache-path $cacheDir `
    -emit-module -emit-module-path (Join-Path $nativeDir 'StudioCore.swiftmodule') `
    -emit-library -static -o (Join-Path $nativeDir 'StudioCore.lib') `
    $coreSources
Assert-ExitCode 'StudioCore compilation'

# 2. The C ABI as a DLL. The .def file is the export surface: without it the
#    host links and then fails at the first P/Invoke.
Step 'building studioscore_core.dll'
$abiSources = @(Get-ChildItem Sources/StudioCoreABI -Filter *.swift |
    ForEach-Object { $_.FullName })
$dll = Join-Path $nativeDir 'studioscore_core.dll'
$def = Join-Path $root 'Windows/native/studioscore_core.def'
& swiftc -O -module-name StudioCoreABI -module-cache-path $cacheDir `
    -I $nativeDir `
    -emit-library -o $dll `
    -Xlinker "/DEF:$def" `
    $abiSources (Join-Path $nativeDir 'StudioCore.lib')
Assert-ExitCode 'StudioCoreABI DLL link'

$expectedExports = @(
    'sc_core_abi_version', 'sc_core_bytes_release', 'sc_project_read',
    'sc_project_write', 'sc_render_plan', 'sc_history_create',
    'sc_history_destroy', 'sc_history_commit', 'sc_history_undo',
    'sc_history_redo', 'sc_history_flags', 'sc_history_mark_clean',
    'sc_history_is_dirty')
$dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
if ($dumpbin) {
    Step 'checking the DLL export table'
    $exports = & dumpbin /exports $dll | Out-String
    foreach ($symbol in $expectedExports) {
        if ($exports -notmatch "(?m)^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+$symbol\s*$") {
            throw "studioscore_core.dll does not export $symbol"
        }
    }
    Write-Host "   all $($expectedExports.Count) exports present"
} else {
    Write-Host '   note: dumpbin is not on PATH; the host tests prove the exports'
}

# 3. The Swift runtime the DLL needs. A machine without the toolchain installed
#    must still run the app, so the runtime DLLs are copied next to the exe.
Step 'collecting the Swift runtime'
$targetInfo = & swiftc -print-target-info | ConvertFrom-Json
Assert-ExitCode 'swiftc -print-target-info'
$runtimeDirs = @($targetInfo.paths.runtimeLibraryPaths) +
    @($targetInfo.paths.runtimeResourcePaths) +
    @(Split-Path (Get-Command swiftc).Source)
$copied = @{}
foreach ($directory in $runtimeDirs) {
    if ($directory -and (Test-Path $directory)) {
        Get-ChildItem $directory -Filter *.dll -File | ForEach-Object {
            if (-not $copied.ContainsKey($_.Name)) {
                Copy-Item $_.FullName $nativeDir -Force
                $copied[$_.Name] = $true
            }
        }
    }
}
Write-Host "   copied $($copied.Count) runtime DLLs"

# 4. A self-contained publish, so the folder runs from a zip with no installed
#    .NET runtime.
if (-not $SkipPublish) {
    Step 'publishing the WPF host (win-x64, self-contained)'
    & dotnet publish (Join-Path $root 'Windows/RetouchStudio.App/RetouchStudio.App.csproj') `
        -c $Configuration -r win-x64 --self-contained true -o $appDir
    Assert-ExitCode 'dotnet publish'

    Get-ChildItem $nativeDir -Filter *.dll -File | ForEach-Object {
        Copy-Item $_.FullName $appDir -Force
    }
    Write-Host "   app published to $appDir"
}

# 5. The headless checks run against the same DLL the app loads.
if (-not $SkipTests) {
    Step 'running the Windows host tests'
    $env:PATH = $nativeDir + ';' + $env:PATH
    & dotnet run --project (Join-Path $root 'Windows/RetouchStudio.Tests/RetouchStudio.Tests.csproj') `
        -c $Configuration
    Assert-ExitCode 'host tests'
}

# 6. A real window from the published exe is the only proof that the GUI, the
#    XAML and the native core all start together. A hosted runner session does
#    not always report MainWindowHandle, so the window writes a marker from its
#    Loaded handler; a window handle is still reported when the session has one.
if (-not $SkipGuiSmoke -and -not $SkipPublish) {
    $exe = Join-Path $appDir 'RetouchStudio.exe'
    if (-not (Test-Path $exe)) {
        throw "$exe was not published"
    }
    Step 'smoke-running the published app'
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $marker = Join-Path $temp 'retouchstudio-smoke.txt'
    $stdout = Join-Path $temp 'retouchstudio-smoke.out'
    $stderr = Join-Path $temp 'retouchstudio-smoke.err'
    Remove-Item $marker, $stdout, $stderr -ErrorAction SilentlyContinue
    # A modal error dialog would itself be a window, so the failure path prints
    # to stderr instead of showing one during the smoke run.
    $env:RETOUCHSTUDIO_NO_DIALOG = '1'
    $env:RETOUCHSTUDIO_SMOKE = $marker
    $process = Start-Process -FilePath $exe -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $title = $null
    $exitCode = $null
    $handle = 0
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            break
        }
        $handle = $process.MainWindowHandle
        if (Test-Path $marker) {
            $title = (Get-Content $marker -Raw).Trim()
            break
        }
    }
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    Remove-Item Env:RETOUCHSTUDIO_NO_DIALOG, Env:RETOUCHSTUDIO_SMOKE -ErrorAction SilentlyContinue
    if ($null -eq $title) {
        $errors = if (Test-Path $stderr) { (Get-Content $stderr -Raw).Trim() } else { '' }
        if ($null -ne $exitCode) {
            throw "the app exited with $exitCode before loading a window. stderr: $errors"
        }
        throw "the app ran but its window never loaded (handle $handle). stderr: $errors"
    }
    Write-Host "   the published app loaded its window: '$title' (native handle $handle)"
}

Write-Host 'WINDOWS APP BUILD: PASS'
