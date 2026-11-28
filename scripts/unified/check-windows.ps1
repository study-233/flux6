param(
    [switch]$CheckWindowExit,
    [switch]$WindowsClient,
    [switch]$OfflinePub,
    [switch]$SkipChecks,
    [string]$Python = 'python',
    [ref]$LiveReleaseDirectory
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$prepareArgs = @(if ($WindowsClient) { '--windows-client' })
$candidate = & $Python (Join-Path $root 'scripts/unified/prepare.py') @prepareArgs
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare unified candidate' }

function Initialize-PluginJunctions {
    $metadata = Get-Content '.flutter-plugins-dependencies' -Raw -Encoding UTF8 | ConvertFrom-Json
    $links = New-Item -ItemType Directory -Force 'windows/flutter/ephemeral/.plugin_symlinks'
    foreach ($plugin in $metadata.plugins.windows) {
        if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid Windows plugin name' }
        $source = (Resolve-Path -LiteralPath $plugin.path).Path.TrimEnd('\')
        $link = Join-Path $links.FullName $plugin.name
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if (-not $item.LinkType -or
                [IO.Path]::GetFullPath(@($item.Target)[0]).TrimEnd('\') -ine $source) {
                throw "Unexpected plugin link: $link"
            }
        } else {
            New-Item -ItemType Junction -Path $link -Target $source | Out-Null
        }
    }
}

function Test-WindowExit($executable, [string]$windowClass) {
    if (-not ('Flux6.PreviewWindow' -as [type])) {
        Add-Type -Namespace Flux6 -Name PreviewWindow -MemberDefinition @'
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);

        public static bool CloseVisibleWindow(uint pid, string windowClass) {
            var window = IntPtr.Zero;
            while ((window = FindWindowEx(IntPtr.Zero, window, windowClass, null)) != IntPtr.Zero) {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner != pid || !IsWindowVisible(window)) continue;
                if (!PostMessageW(window, 0x0010 /* WM_CLOSE */, UIntPtr.Zero, IntPtr.Zero)) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                return true;
            }
            return false;
        }
'@
    }
    $start = [Diagnostics.ProcessStartInfo]::new($executable.FullName)
    $start.WorkingDirectory = $executable.DirectoryName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (-not [Flux6.PreviewWindow]::CloseVisibleWindow($process.Id, $windowClass)) {
            if ($process.HasExited) { throw "Preview exited before showing a window ($($process.ExitCode))" }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the visible preview window' }
            Start-Sleep -Milliseconds 200
        }
        if (-not $process.WaitForExit(15000)) { throw 'Timed out closing the preview window' }
        if ($process.ExitCode -ne 0) { throw "Preview close failed ($($process.ExitCode))" }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Build-WindowsClient {
    $fixtureFlags = @('--dart-define=SAFE_MODE=true', '--dart-define=FREEV6_OFFLINE=true')
    if (-not $SkipChecks) {
        flutter test --no-pub @fixtureFlags test/freev6
        if ($LASTEXITCODE -ne 0) { throw 'Windows client offline tests failed' }
    }
    flutter build windows --release --no-pub --flavor preview --target lib/fixture_main.dart @fixtureFlags
    if ($LASTEXITCODE -ne 0) { throw 'Windows fixture build failed' }
    $fixture = Get-Item 'build/windows/x64/preview/runner/Release/freev6-windows-preview.exe'
    $probe = Start-Process -FilePath $fixture.FullName -WorkingDirectory $fixture.DirectoryName -ArgumentList '--host-probe' -WindowStyle Hidden -PassThru
    try {
        if (-not $probe.WaitForExit(30000)) { throw 'Windows fixture host probe timed out' }
        if ($probe.ExitCode -ne 0) { throw "Windows fixture host probe failed ($($probe.ExitCode))" }
    } finally {
        if (-not $probe.HasExited) { $probe.Kill(); $probe.WaitForExit() }
        $probe.Dispose()
    }
    if ($CheckWindowExit) { Test-WindowExit $fixture 'FLUTTER_RUNNER_WIN32_WINDOW' }
    $releaseVersion = Get-Content (Join-Path $root 'apps/windows/release.json') -Raw | ConvertFrom-Json
    flutter build windows --release --no-pub --flavor live --dart-define=FREEV6_BACKEND=true "--build-name=$($releaseVersion.version)" "--build-number=$($releaseVersion.build)"
    if ($LASTEXITCODE -ne 0) { throw 'Windows live client build failed' }
    $executable = Get-Item 'build/windows/x64/live/runner/Release/freev6-desktop.exe'
    & (Join-Path $root 'scripts/windows/build-helper.ps1') -BundleDirectory $executable.DirectoryName
    Copy-Item -LiteralPath (Join-Path $root 'GeoSite.dat') -Destination $executable.DirectoryName
    if ($null -ne $LiveReleaseDirectory) { $LiveReleaseDirectory.Value = $executable.DirectoryName }
    $executable
}

$previousNoProxy = $env:NO_PROXY
$previousRustLibDir = $env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR
Push-Location $candidate
try {
    $env:NO_PROXY = (@($previousNoProxy, '127.0.0.1', 'localhost', '::1') -ne '') -join ','
    $pubLog = Join-Path $candidate 'pub-get.log'
    $pubCommand = if ($OfflinePub) { 'flutter pub get --offline --enforce-lockfile' } else { 'flutter pub get --enforce-lockfile' }
    cmd.exe /d /c "$pubCommand >pub-get.log 2>&1"
    $pubExit = $LASTEXITCODE
    Get-Content $pubLog
    if ($pubExit -ne 0) {
        if (!(Test-Path '.flutter-plugins-dependencies') -or
            !(Select-String -Path $pubLog -Pattern 'requires symlink support|ERROR_PRIVILEGE_NOT_HELD|errno = 1314' -Quiet)) {
            throw 'Locked dependency preparation failed'
        }
        Initialize-PluginJunctions
        flutter pub get --offline --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Locked dependency check failed after preparing plugin junctions' }
    }
    if ($WindowsClient) {
        dart run intl_utils:generate
        if ($LASTEXITCODE -ne 0) { throw 'Windows localization generation failed' }
    }
    if (-not $SkipChecks) {
        flutter analyze --no-pub --no-fatal-infos
        if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    }
    if ($WindowsClient) {
        Build-WindowsClient
        return
    }
    flutter test --no-pub test/unified_node_groups_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Unified preview test failed' }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows x64 build failed' }
    $executable = Get-Item 'build/windows/x64/runner/Release/flux6-unified-preview.exe'
    if ($CheckWindowExit) {
        Test-WindowExit $executable 'FLUX6_UNIFIED_PREVIEW_WINDOW'
        Write-Host 'Preview window closed with exit code 0.'
    }
    $env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = (Join-Path $candidate 'build/native_assets/windows')
    flutter test --no-pub test/unified_desktop_profile_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Desktop profile preparation test failed' }
    $executable
} finally {
    $env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = $previousRustLibDir
    $env:NO_PROXY = $previousNoProxy
    Pop-Location
}
