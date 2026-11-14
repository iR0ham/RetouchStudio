# Builds the Windows host end to end on a native Windows machine: the StudioCore
# C ABI as studioscore_core.dll, a self-contained x64 publish of the WPF app,
# the headless host tests against the real DLL and Windows Imaging Component,
# a GUI liveness check that the published exe opens a window, the same check
# from the extracted release zip, and, when WiX Toolset v3 is installed, an MSI
# that is silently installed, started from Program Files and uninstalled again.
#
#   pwsh -File Tools/build-windows.ps1
#   pwsh -File Tools/build-windows.ps1 -SkipGuiSmoke     # no interactive desktop
#   pwsh -File Tools/build-windows.ps1 -SkipPackage      # no zip or MSI artifact
#   pwsh -File Tools/build-windows.ps1 -PackageVersion 1.2.3
#   pwsh -File Tools/build-windows.ps1 -RequireMsi        # CI: no silent skip
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
    [switch]$SkipPublish,
    [switch]$SkipPackage,
    [switch]$RequireMsi,
    [string]$PackageVersion = '0.0.0-ci'
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
    $process = Start-Process -FilePath $Exe -PassThru `
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
    Write-Host "   the $Label app loaded its window: '$title' (native handle $handle)"
}

if (-not $SkipGuiSmoke -and -not $SkipPublish) {
    Step 'smoke-running the published app'
    Invoke-GuiSmoke (Join-Path $appDir 'RetouchStudio.exe') 'published'
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
#    it is uninstalled again. WiX v3 is not on every developer machine, so the
#    MSI is skipped when the toolset is absent; the CI image has it and proves
#    the whole path.
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

function Invoke-InstallProof([string]$Msi, [string]$Label) {
    $installDir = Join-Path $env:ProgramFiles 'Retouch Studio'
    $installedExe = Join-Path $installDir 'RetouchStudio.exe'
    $shortcutDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Retouch Studio'
    $shortcut = Join-Path $shortcutDir 'Retouch Studio.lnk'
    if (Test-Path $installDir) {
        throw "$installDir already exists; the install proof needs a clean machine state"
    }

    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $installLog = Join-Path $temp 'retouchstudio-msi-install.log'
    $uninstallLog = Join-Path $temp 'retouchstudio-msi-uninstall.log'
    Remove-Item $installLog, $uninstallLog -ErrorAction SilentlyContinue

    $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
    $install = Start-Process $msiexec -PassThru -Wait -ArgumentList @(
        '/i', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$installLog`"")
    if ($install.ExitCode -notin 0, 3010, 1641) {
        throw "msiexec /i exited with $($install.ExitCode); see $installLog"
    }
    if (-not (Test-Path $installedExe -PathType Leaf)) {
        throw "the MSI did not install $installedExe; see $installLog"
    }
    if (-not (Test-Path $shortcut -PathType Leaf)) {
        throw "the MSI did not create $shortcut; see $installLog"
    }
    Write-Host "   installed $installedExe"

    Invoke-GuiSmoke $installedExe $Label

    $uninstall = Start-Process $msiexec -PassThru -Wait -ArgumentList @(
        '/x', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$uninstallLog`"")
    if ($uninstall.ExitCode -notin 0, 3010, 1641) {
        throw "msiexec /x exited with $($uninstall.ExitCode); see $uninstallLog"
    }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not (Test-Path $installDir)) { break }
        Start-Sleep -Seconds 1
    }
    if (Test-Path $installDir) {
        throw "the uninstall left $installDir behind; see $uninstallLog"
    }
    if (Test-Path $shortcut) {
        throw "the uninstall left $shortcut behind; see $uninstallLog"
    }
    Write-Host '   uninstalled; the install folder and the shortcut are gone'
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
        $msiName = "RetouchStudio-$PackageVersion-windows-x64.msi"
        $msi = Join-Path $distDir $msiName
        & (Join-Path $root 'Tools/package-windows-msi.ps1') `
            -AppDir $appDir -Version $PackageVersion -OutputDir $distDir -WixDir $wix
        Assert-ExitCode 'MSI packaging'
        $msiManifest = "$msi.sha256"
        if (-not (Test-Path $msi -PathType Leaf)) { throw "$msi was not written" }
        if (-not (Test-Path $msiManifest -PathType Leaf)) { throw "$msiManifest was not written" }
        $recorded = (Get-Content $msiManifest -Raw).Trim()
        $hash = (Get-FileHash -Path $msi -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($recorded -ne "$hash  $msiName") {
            throw "the MSI manifest does not match the MSI: '$recorded'"
        }
        $size = (Get-Item $msi).Length
        Write-Host "   $msiName ($size bytes), sha256 $hash"

        if (-not $SkipGuiSmoke) {
            Step 'installing and uninstalling the MSI'
            Invoke-InstallProof $msi 'installed'
        }
    }
}

Write-Host 'WINDOWS APP BUILD: PASS'
