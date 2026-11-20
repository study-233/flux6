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
    $process = Start-Process -FilePath $executable.FullName -WorkingDirectory $executable.DirectoryName -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            $process.Refresh()
            if ($process.HasExited) { throw "Preview exited before showing a window ($($process.ExitCode))" }
            if ($process.MainWindowHandle -ne 0) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $process.CloseMainWindow()) { throw 'No preview window accepted WM_CLOSE' }
        if (-not $process.WaitForExit(15000)) { throw 'Timed out closing the preview window' }
        if ($process.ExitCode -ne 0) { throw "Preview close failed ($($process.ExitCode))" }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

$previousNoProxy = $env:NO_PROXY
Push-Location $candidate
try {
    $env:NO_PROXY = (@($previousNoProxy, '127.0.0.1', 'localhost', '::1') -ne '') -join ','
    $pubLog = Join-Path $candidate 'pub-get.log'
    flutter pub get --enforce-lockfile *> $pubLog
    Get-Content $pubLog
    if ($LASTEXITCODE -ne 0) {
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
    if ($LASTEXITCODE -ne 0) { throw 'Shared node page test failed' }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows x64 build failed' }
    $executable = Get-Item 'build/windows/x64/runner/Release/flux6-unified-preview.exe'
    if ($CheckWindowExit) { Test-WindowExit $executable }
    $executable
} finally {
    $env:NO_PROXY = $previousNoProxy
    Pop-Location
}
