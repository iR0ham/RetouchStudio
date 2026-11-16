# Builds the Windows host end to end on a native Windows machine: the StudioCore
# C ABI as studioscore_core.dll, a self-contained x64 publish of the WPF app,
# the headless host tests against the real DLL and Windows Imaging Component,
# a GUI liveness check that the published exe opens a window, the same check
# from the extracted release zip, and, when WiX Toolset v3 is installed, an MSI
# that is silently installed, started from Program Files, upgraded in place by a
# higher version and uninstalled again.
#
#   pwsh -File Tools/build-windows.ps1
#   pwsh -File Tools/build-windows.ps1 -SkipGuiSmoke     # no interactive desktop
#   pwsh -File Tools/build-windows.ps1 -SkipUiSmoke      # no UI automation
#   pwsh -File Tools/build-windows.ps1 -SkipPackage      # no zip or MSI artifact
#   pwsh -File Tools/build-windows.ps1 -PackageVersion 1.2.3
#   pwsh -File Tools/build-windows.ps1 -RequireMsi        # CI: no silent skip
#
# -PackageVersion stamps the published assembly and names the zip and the MSI.
# It defaults to the Version in Windows/Directory.Build.props, and a release
# passes the tag version.
#
# Requires a Swift toolchain for Windows (swiftc.exe plus its clang.exe and lld)
# and the .NET 10 SDK, both on PATH. The MSI needs WiX Toolset v3, which the CI
# image has; without it the installer step is skipped and everything else runs.
# Intel and AMD machines run the same x64 build; there is no vendor-specific
# artifact.

param(
    [string]$Configuration = 'Release',
    [switch]$SkipTests,
    [switch]$SkipGuiSmoke,
    [switch]$SkipUiSmoke,
    [switch]$SkipPublish,
    [switch]$SkipPackage,
    [switch]$RequireMsi,
    # One version for the whole build: the published assembly, the zip name and
    # the MSI. A release passes the tag version; otherwise it is the shared
    # Windows version, so the binary and the artifacts cannot disagree.
    [string]$PackageVersion = ([xml](Get-Content `
        (Join-Path $PSScriptRoot '../Windows/Directory.Build.props'))).Project.PropertyGroup.Version
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
$aiTestDir = Join-Path $root 'build/windows/ai'
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
# Only ship Swift's redistributable runtime locations. The directory containing
# swiftc.exe is the compiler toolchain (LLVM, LLDB, SourceKit, SwiftSyntax,
# build-system and indexing tools), not an application runtime directory.
# Copying every DLL from that directory bloats the app by hundreds of MiB.
$runtimeDirs = @($targetInfo.paths.runtimeLibraryPaths) +
    @($targetInfo.paths.runtimeResourcePaths)
# The runtime location is not purely runtime either: it also carries the
# compiler/debugger side (LLDB, SourceKit, the index store, the SwiftScan
# plugin, clang and LTO), and the zip shipped all of it. No StudioCore runtime
# module imports these, which the publish step below checks from the import
# tables, so they are never copied.
$toolchainOnlyDlls = @(
    'liblldb.dll', 'sourcekitdInProc.dll', '_InternalSwiftScan.dll',
    'libclang.dll', 'LTO.dll', 'libIndexStore.dll',
    '_InternalSwiftStaticMirror.dll'
)
$copied = @{}
$leftOut = @{}
foreach ($directory in $runtimeDirs) {
    if ($directory -and (Test-Path $directory)) {
        Get-ChildItem $directory -Filter *.dll -File | ForEach-Object {
            if ($toolchainOnlyDlls -contains $_.Name) {
                $leftOut[$_.Name] = $_.Length
                return
            }
            if (-not $copied.ContainsKey($_.Name)) {
                Copy-Item $_.FullName $nativeDir -Force
                $copied[$_.Name] = $true
            }
        }
    }
}
Write-Host "   copied $($copied.Count) runtime DLLs"
if ($leftOut.Count -gt 0) {
    $leftOutMiB = ($leftOut.Values | Measure-Object -Sum).Sum / 1MB
    Write-Host ("   left out {0} toolchain DLLs ({1:N1} MiB): {2}" -f
        $leftOut.Count, $leftOutMiB, (($leftOut.Keys | Sort-Object) -join ', '))
}

# 4. The pinned runtime package is verified before anything consumes it, so a
#    cache or feed substitution cannot silently change the shipped CPU provider.
Step 'restoring and verifying the pinned ONNX Runtime package'
& dotnet restore (Join-Path $root 'Windows/RetouchStudio.AI/RetouchStudio.AI.csproj')
Assert-ExitCode 'ONNX Runtime restore'
$nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } `
    else { Join-Path $env:USERPROFILE '.nuget/packages' }
$nupkg = Join-Path $nugetRoot `
    'microsoft.ml.onnxruntime/1.32.0/microsoft.ml.onnxruntime.1.32.0.nupkg'
if (-not (Test-Path $nupkg)) {
    throw "the pinned ONNX Runtime package is missing at $nupkg"
}
$package = Get-Item $nupkg
$packageHash = (Get-FileHash $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
if ($package.Length -ne 184391411 -or
    $packageHash -ne 'a9150bc2992cbbb6722070da9910e1ffa989a8bfc67bdd5bb8e745ca755641db') {
    throw "ONNX Runtime package differs: $($package.Length) bytes, SHA-256 $packageHash"
}
Write-Host '   ONNX Runtime 1.32.0 matches the recorded size and SHA-256'

# The worker the tests launch is a framework-dependent publish of the real
# project. The app gets its own self-contained publish under AI/ below.
Step 'publishing the AI worker for the runtime tests'
& dotnet publish (Join-Path $root 'Windows/RetouchStudio.AI.Worker/RetouchStudio.AI.Worker.csproj') `
    -c $Configuration -r win-x64 --self-contained false -o $aiTestDir
Assert-ExitCode 'AI worker publish'
$env:RETOUCH_AI_WORKER = Join-Path $aiTestDir 'RetouchStudio.AI.Worker.exe'

# 4b. A self-contained publish, so the folder runs from a zip with no installed
#     .NET runtime.
if (-not $SkipPublish) {
    Step 'publishing the WPF host (win-x64, self-contained)'
    # The assembly takes the same version as the zip and the MSI. Without this
    # the binary keeps Directory.Build.props' Version while the artifacts are
    # named from the tag, so a release would ship a mislabelled executable.
    & dotnet publish (Join-Path $root 'Windows/RetouchStudio.App/RetouchStudio.App.csproj') `
        -c $Configuration -r win-x64 --self-contained true -o $appDir `
        -p:Version=$PackageVersion
    Assert-ExitCode 'dotnet publish'

    Step 'publishing the AI worker and its native payload into the app'
    $appAiDir = Join-Path $appDir 'AI'
    & dotnet publish (Join-Path $root 'Windows/RetouchStudio.AI.Worker/RetouchStudio.AI.Worker.csproj') `
        -c $Configuration -r win-x64 --self-contained true -o $appAiDir `
        -p:Version=$PackageVersion
    Assert-ExitCode 'AI worker app publish'

    # The package's licence and third-party notices travel beside the native
    # payload they cover.
    foreach ($notice in @('LICENSE', 'ThirdPartyNotices.txt')) {
        $source = Join-Path (Split-Path $nupkg -Parent) $notice
        if (Test-Path $source) {
            Copy-Item $source $appAiDir -Force
        }
    }

    Get-ChildItem $nativeDir -Filter *.dll -File | ForEach-Object {
        Copy-Item $_.FullName $appDir -Force
    }

    # The runtime the host will launch must travel with the host: the worker
    # executable, the protocol library and ORT's native DLL, with no Python.
    foreach ($required in @('AI/RetouchStudio.AI.Worker.exe',
            'AI/RetouchStudio.AI.dll', 'AI/onnxruntime.dll')) {
        if (-not (Test-Path (Join-Path $appDir $required) -PathType Leaf)) {
            throw "the published app is missing $required"
        }
    }
    Write-Host '   AI worker, protocol library and ORT CPU payload present'

    # Guard against accidentally shipping compiler/debugger tooling again.
    # These are not part of the StudioCore runtime dependency closure.
    foreach ($name in $toolchainOnlyDlls) {
        if (Test-Path (Join-Path $appDir $name) -PathType Leaf) {
            throw "Unexpected Swift toolchain DLL in app payload: $name"
        }
    }
    if ($dumpbin) {
        # Leaving a DLL out is only safe if nothing in the payload imports it.
        Step 'checking the payload does not import toolchain DLLs'
        $modules = @(Get-ChildItem $appDir -File |
            Where-Object { $_.Extension -in '.dll', '.exe' })
        foreach ($module in $modules) {
            $imports = & dumpbin /nologo /dependents $module.FullName | Out-String
            Assert-ExitCode "dumpbin /dependents $($module.Name)"
            foreach ($name in $toolchainOnlyDlls) {
                if ($imports -match "(?im)^\s+$([regex]::Escape($name))\s*$") {
                    throw "$($module.Name) imports $name, so it cannot be left out"
                }
            }
        }
        Write-Host "   $($modules.Count) payload modules import none of the $($toolchainOnlyDlls.Count) excluded DLLs"
    }

    $appBytes = (Get-ChildItem $appDir -File -Recurse | Measure-Object -Property Length -Sum).Sum
    Write-Host ("   app payload: {0:N1} MiB" -f ($appBytes / 1MB))
    Write-Host "   app published to $appDir"
}

# 5. The headless checks run against the same DLL the app loads.
if (-not $SkipTests) {
    Step 'running the Windows host tests'
    $env:PATH = $nativeDir + ';' + $env:PATH
    & dotnet run --project (Join-Path $root 'Windows/RetouchStudio.Tests/RetouchStudio.Tests.csproj') `
        -c $Configuration
    Assert-ExitCode 'host tests'

    # A real worker process, a real named pipe and a real Job Object: this is
    # the evidence that the C# runtime speaks protocol 2, not just that it
    # compiles.
    Step 'running the AI runtime tests'
    $env:RETOUCH_TESTS_ROOT = $root
    & dotnet run --project (Join-Path $root 'Windows/RetouchStudio.AI.Tests/RetouchStudio.AI.Tests.csproj') `
        -c $Configuration
    Assert-ExitCode 'AI runtime tests'
}

# 6. A real window from the published exe is the only proof that the GUI, the
#    XAML and the native core all start together. A hosted runner session does
#    not always report MainWindowHandle, so the window writes a marker from its
#    Loaded handler; a window handle is still reported when the session has one.
function Invoke-GuiSmoke([string]$Exe, [string]$Label) {
    if (-not (Test-Path $Exe)) {
        throw "$Exe was not published"
    }
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $marker = Join-Path $temp 'retouchstudio-smoke.txt'
    $stdout = Join-Path $temp 'retouchstudio-smoke.out'
    $stderr = Join-Path $temp 'retouchstudio-smoke.err'
    Remove-Item $marker, $stdout, $stderr -ErrorAction SilentlyContinue
    # A modal error dialog would itself be a window, so the failure path prints
    # to stderr instead of showing one during the smoke run.
    $env:RETOUCHSTUDIO_NO_DIALOG = '1'
    $env:RETOUCHSTUDIO_SMOKE = $marker
    # The clock runs from process start to the window's Loaded marker, so the
    # line reports a real start-up time on this runner. It is recorded, not
    # gated: a hosted runner's first window is too noisy for a budget.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Exe -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $title = $null
    $exitCode = $null
    $handle = 0
    $loadedMs = -1
    for ($attempt = 0; $attempt -lt 300; $attempt++) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            break
        }
        $handle = $process.MainWindowHandle
        if (Test-Path $marker) {
            $title = (Get-Content $marker -Raw).Trim()
            $loadedMs = $watch.ElapsedMilliseconds
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
    Write-Host "   the $Label app loaded its window in $loadedMs ms: '$title' (native handle $handle)"
}

if (-not $SkipGuiSmoke -and -not $SkipPublish) {
    Step 'smoke-running the published app'
    Invoke-GuiSmoke (Join-Path $appDir 'RetouchStudio.exe') 'published'
}

# 6b. A window proves the app starts; it does not prove a click reaches the
#     renderer. An automation client drives the published exe through its own
#     Open and Export dialogs, moves the Exposure slider and decodes the file
#     it wrote. An isolated recovery folder keeps a stale copy off the screen.
if (-not $SkipUiSmoke -and -not $SkipGuiSmoke -and -not $SkipPublish) {
    Step 'driving the published app through Windows UI Automation'
    $uiTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $uiOutput = Join-Path $uiTemp 'retouchstudio-ui-export.jpg'
    $uiProject = Join-Path $root 'Windows/RetouchStudio.UiTests/RetouchStudio.UiTests.csproj'
    $uiApp = Join-Path $appDir 'RetouchStudio.exe'
    $uiPhoto = Join-Path $root 'Tests/Corpus/Fixtures/F01_portrait_srgb_8.png'
    & dotnet run --project $uiProject -c $Configuration -- $uiApp $uiPhoto $uiOutput
    Assert-ExitCode 'UI host tests'

    # The launch prompt for an unsaved copy is a message box no headless test
    # can answer, so a copy is seeded and the prompt is driven the same way.
    $uiRecoveryOutput = Join-Path $uiTemp 'retouchstudio-ui-recovery.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiRecoveryOutput recovery
    Assert-ExitCode 'UI recovery tests'

    # The other answer: "No" must drop that copy and leave the next launch quiet.
    $uiDeclineOutput = Join-Path $uiTemp 'retouchstudio-ui-recovery-no.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiDeclineOutput recoveryno
    Assert-ExitCode 'UI recovery decline tests'

    # Export must name the edits this host cannot render; "No" writes nothing.
    $uiGuardOutput = Join-Path $uiTemp 'retouchstudio-ui-guard.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiGuardOutput guard
    Assert-ExitCode 'UI guard tests'

    # Save Project carries the edit through its dialog; Undo must reach history.
    $uiProjectOutput = Join-Path $uiTemp 'retouchstudio-ui-project.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiProjectOutput project
    Assert-ExitCode 'UI project tests'

    # Batch export runs from the UI: photo picker, folder picker, written file.
    $uiBatchOutput = Join-Path $uiTemp 'retouchstudio-ui-batch.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiBatchOutput batch
    Assert-ExitCode 'UI batch tests'

    # A crop is drawn by a pointer gesture, which no UIA pattern can express:
    # the corner handle is dragged with real mouse input and the exported
    # frame must equal the size the overlay shows.
    $uiCropOutput = Join-Path $uiTemp 'retouchstudio-ui-crop.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiCropOutput crop
    Assert-ExitCode 'UI crop tests'

    # The compare divider is dragged the same way; the Thumb's own rectangle is
    # the evidence, because the split line and badges are not in the UIA tree.
    $uiCompareOutput = Join-Path $uiTemp 'retouchstudio-ui-compare.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiCompareOutput compare
    Assert-ExitCode 'UI compare tests'

    # Zoom and pan are pointer gestures too: the dock's label reports the zoom,
    # and a screen hash proves the drag moved the photo and Fit restored it.
    $uiZoomOutput = Join-Path $uiTemp 'retouchstudio-ui-zoom.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiZoomOutput zoom
    Assert-ExitCode 'UI zoom tests'

    # A running batch is stopped by its own button; the status line names how
    # many photos landed, and the folder must hold exactly that many.
    $uiCancelOutput = Join-Path $uiTemp 'retouchstudio-ui-batch-cancel.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiCancelOutput batchcancel
    Assert-ExitCode 'UI batch cancel tests'

    # A corrupt photo and a locked destination must each end in a message the
    # person reads, and the failed export must leave the locked file alone.
    $uiErrorOutput = Join-Path $uiTemp 'retouchstudio-ui-errors.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiErrorOutput errors
    Assert-ExitCode 'UI error tests'

    # Drop-to-open is an OLE drop no UIA pattern can express: a helper drag
    # source drops the photo on the preview. The opened title and the exported
    # file prove the drop reached the same open path the dialogs use.
    $uiDropOutput = Join-Path $uiTemp 'retouchstudio-ui-drop.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiDropOutput drop
    Assert-ExitCode 'UI drop tests'

    # The single-export Cancel button is clicked while a 24-megapixel 16-bit
    # PNG is still being encoded: nothing may land at the destination and the
    # temp sibling must be gone. The output name is a placeholder; the mode
    # switches it to .png where the export's 16-bit path lives.
    $uiExportCancelOutput = Join-Path $uiTemp 'retouchstudio-ui-export-cancel.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiExportCancelOutput exportcancel
    Assert-ExitCode 'UI export cancel tests'

    # Closing the window mid-export must cancel the work and let it unwind
    # before the process exits, with the same whole-or-absent destination.
    $uiExportCloseOutput = Join-Path $uiTemp 'retouchstudio-ui-export-close.jpg'
    & dotnet run --project $uiProject -c $Configuration -- `
        $uiApp $uiPhoto $uiExportCloseOutput exportclose
    Assert-ExitCode 'UI export close tests'
}

# 7. The zip is what a release would ship, so the artifact itself is extracted
#    and started, not just the publish folder it was made from.
if (-not $SkipPackage -and -not $SkipGuiSmoke -and -not $SkipPublish) {
    Step 'packaging the published app'
    $distDir = Join-Path $root 'build/windows/dist'
    & (Join-Path $root 'Tools/package-windows.ps1') `
        -AppDir $appDir -Version $PackageVersion -OutputDir $distDir
    Assert-ExitCode 'packaging'

    $zipName = "RetouchStudio-$PackageVersion-windows-x64.zip"
    $zip = Join-Path $distDir $zipName
    $manifest = "$zip.sha256"
    if (-not (Test-Path $zip -PathType Leaf)) { throw "$zip was not written" }
    if (-not (Test-Path $manifest -PathType Leaf)) { throw "$manifest was not written" }
    $recorded = (Get-Content $manifest -Raw).Trim()
    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($recorded -ne "$hash  $zipName") {
        throw "the zip manifest does not match the zip: '$recorded'"
    }
    $size = (Get-Item $zip).Length
    Write-Host "   $zipName ($size bytes), sha256 $hash"

    Step 'smoke-running the packaged zip'
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $extracted = Join-Path $temp 'retouchstudio-packaged'
    Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $extracted
    Invoke-GuiSmoke (Join-Path $extracted 'RetouchStudio.exe') 'packaged'
}

# 8. The MSI is the artifact a user runs, so it is not merely built: it is
#    installed silently, the installed copy is started from Program Files, and
#    it is uninstalled again. A second package with a higher version is then
#    installed over the first, because that is the state a user is in when the
#    next version ships. WiX v3 is not on every developer machine, so the MSI is
#    skipped when the toolset is absent; the CI image has it and proves the
#    whole path.
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

function Get-InstalledProducts {
    $uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $uninstall -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Retouch Studio' })
}

function Get-InstallPaths {
    $dir = Join-Path $env:ProgramFiles 'Retouch Studio'
    [pscustomobject]@{
        Dir      = $dir
        Exe      = Join-Path $dir 'RetouchStudio.exe'
        Shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Retouch Studio\Retouch Studio.lnk'
    }
}

function Assert-CleanInstall {
    $paths = Get-InstallPaths
    if (Test-Path $paths.Dir) {
        throw "$($paths.Dir) already exists; the installer proof needs a clean state"
    }
    if (@(Get-InstalledProducts).Count -ne 0) {
        throw 'Retouch Studio is already registered in Programs and Features'
    }
}

function Install-Msi([string]$Msi, [string]$ExpectedVersion) {
    $paths = Get-InstallPaths
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $log = Join-Path $temp ("retouchstudio-msi-" + [guid]::NewGuid().ToString('N') + ".log")
    $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
    $install = Start-Process $msiexec -PassThru -Wait -ArgumentList @(
        '/i', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
    if ($install.ExitCode -notin 0, 3010, 1641) {
        throw "msiexec /i $Msi exited with $($install.ExitCode); see $log"
    }
    if (-not (Test-Path $paths.Exe -PathType Leaf)) {
        throw "the MSI did not install $($paths.Exe); see $log"
    }
    if (-not (Test-Path $paths.Shortcut -PathType Leaf)) {
        throw "the MSI did not create $($paths.Shortcut); see $log"
    }
    $products = @(Get-InstalledProducts)
    if ($products.Count -ne 1) {
        throw "expected one Retouch Studio entry in Programs and Features, found $($products.Count); see $log"
    }
    if ($products[0].DisplayVersion -ne $ExpectedVersion) {
        throw "the installed product reports '$($products[0].DisplayVersion)', not '$ExpectedVersion'; see $log"
    }
    Write-Host "   installed $($paths.Exe) as $($products[0].DisplayVersion)"
}

function Uninstall-Msi([string]$Msi) {
    $paths = Get-InstallPaths
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $log = Join-Path $temp ("retouchstudio-msi-uninstall-" + [guid]::NewGuid().ToString('N') + ".log")
    $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
    $uninstall = Start-Process $msiexec -PassThru -Wait -ArgumentList @(
        '/x', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
    if ($uninstall.ExitCode -notin 0, 3010, 1641) {
        throw "msiexec /x $Msi exited with $($uninstall.ExitCode); see $log"
    }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not (Test-Path $paths.Dir)) { break }
        Start-Sleep -Seconds 1
    }
    if (Test-Path $paths.Dir) {
        throw "the uninstall left $($paths.Dir) behind; see $log"
    }
    if (Test-Path $paths.Shortcut) {
        throw "the uninstall left $($paths.Shortcut) behind; see $log"
    }
    if (@(Get-InstalledProducts).Count -ne 0) {
        throw "the uninstall left Retouch Studio in Programs and Features; see $log"
    }
    Write-Host '   uninstalled; the folder, the shortcut and the entry are gone'
}

function Get-MsiVersion([string]$Version) {
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
        throw "Version '$Version' has no numeric major.minor.patch prefix"
    }
    "$($matches[1]).$($matches[2]).$($matches[3]).0"
}

function Get-NextPackageVersion([string]$Version) {
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
        throw "Version '$Version' has no numeric major.minor.patch prefix"
    }
    $next = "$($matches[1]).$($matches[2]).$([int]$matches[3] + 1)"
    $next + $Version.Substring($matches[0].Length)
}

function Build-Msi([string]$Wix, [string]$Version) {
    # heat, candle and light write their progress to stdout; Out-Host keeps that
    # in the log without mixing it into this function's return value.
    & (Join-Path $root 'Tools/package-windows-msi.ps1') `
        -AppDir $appDir -Version $Version -OutputDir $distDir -WixDir $Wix | Out-Host
    Assert-ExitCode 'MSI packaging'
    $name = "RetouchStudio-$Version-windows-x64.msi"
    $path = Join-Path $distDir $name
    $manifest = "$path.sha256"
    if (-not (Test-Path $path -PathType Leaf)) { throw "$path was not written" }
    if (-not (Test-Path $manifest -PathType Leaf)) { throw "$manifest was not written" }
    $recorded = (Get-Content $manifest -Raw).Trim()
    $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($recorded -ne "$hash  $name") {
        throw "the MSI manifest does not match the MSI: '$recorded'"
    }
    $size = (Get-Item $path).Length
    Write-Host "   $name ($size bytes), sha256 $hash"
    return $path
}

if (-not $SkipPackage -and -not $SkipPublish) {
    $wix = Find-Wix ''
    if (-not $wix) {
        if ($RequireMsi) {
            throw 'WiX Toolset v3 was not found and -RequireMsi was passed'
        }
        Write-Host '   WiX Toolset v3 not found: the MSI installer is not built'
    }
    else {
        Step 'building the MSI installer'
        Write-Host "   WiX at $wix"
        $msi = Build-Msi $wix $PackageVersion
        if ($msi -isnot [string] -or -not (Test-Path $msi -PathType Leaf)) {
            throw "the MSI build did not return one file; it returned '$msi'"
        }

        if (-not $SkipGuiSmoke) {
            Step 'installing, starting and uninstalling the MSI'
            Assert-CleanInstall
            Install-Msi $msi (Get-MsiVersion $PackageVersion)
            Invoke-GuiSmoke ((Get-InstallPaths).Exe) 'installed'
            Uninstall-Msi $msi

            # An installed product is the state every user is in when the next
            # version ships, so the upgrade rule is proved, not just declared:
            # a second package built from the same folder replaces the first in
            # place, leaving one entry and the new version.
            Step 'upgrading an installed version'
            $upgradeVersion = Get-NextPackageVersion $PackageVersion
            $upgradeMsi = Build-Msi $wix $upgradeVersion
            if ($upgradeMsi -isnot [string] -or -not (Test-Path $upgradeMsi -PathType Leaf)) {
                throw "the upgrade MSI build did not return one file; it returned '$upgradeMsi'"
            }
            Install-Msi $msi (Get-MsiVersion $PackageVersion)
            Install-Msi $upgradeMsi (Get-MsiVersion $upgradeVersion)
            Invoke-GuiSmoke ((Get-InstallPaths).Exe) 'upgraded'
            Uninstall-Msi $upgradeMsi
            Write-Host "   upgraded in place from $(Get-MsiVersion $PackageVersion) to $(Get-MsiVersion $upgradeVersion)"

            # The upgrade package exists only to prove the rule. Leaving it in
            # dist would publish two versions as the release's installers, so
            # only the package built for this run stays.
            foreach ($leftover in @($upgradeMsi,
                                   "$upgradeMsi.sha256",
                                   [IO.Path]::ChangeExtension($upgradeMsi, '.wixpdb'))) {
                if (Test-Path $leftover -PathType Leaf) {
                    Remove-Item $leftover -Force
                }
            }
            $stray = @(Get-ChildItem $distDir -Filter 'RetouchStudio-*-windows-x64.msi' |
                       Where-Object { $_.FullName -ne $msi })
            if ($stray.Count -gt 0) {
                throw "dist holds an extra MSI after the upgrade test: $($stray.Name -join ', ')"
            }
            Write-Host "   dist holds the one package for this run: $(Split-Path $msi -Leaf)"
        }
    }
}

Write-Host 'WINDOWS APP BUILD: PASS'
