param([switch]$CheckWindowExit)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$candidate = python (Join-Path $root 'scripts/unified/prepare.py')
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

function Test-WindowExit($executable) {
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

        public static bool CloseVisibleWindow(uint pid) {
            var window = IntPtr.Zero;
            while ((window = FindWindowEx(IntPtr.Zero, window, "FLUX6_UNIFIED_PREVIEW_WINDOW", null)) != IntPtr.Zero) {
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
        while (-not [Flux6.PreviewWindow]::CloseVisibleWindow($process.Id)) {
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

$previousNoProxy = $env:NO_PROXY
$previousRustLibDir = $env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR
Push-Location $candidate
try {
    $env:NO_PROXY = (@($previousNoProxy, '127.0.0.1', 'localhost', '::1') -ne '') -join ','
    $pubLog = Join-Path $candidate 'pub-get.log'
    cmd.exe /d /c 'flutter pub get --enforce-lockfile >pub-get.log 2>&1'
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
    flutter analyze --no-pub --no-fatal-infos
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    flutter test --no-pub test/unified_node_groups_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Unified preview test failed' }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows x64 build failed' }
    $executable = Get-Item 'build/windows/x64/runner/Release/flux6-unified-preview.exe'
    if ($CheckWindowExit) {
        Test-WindowExit $executable
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
