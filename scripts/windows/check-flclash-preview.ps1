param(
    [string]$FlutterSdk = $env:FREEV6_FLUTTER_SDK,
    [switch]$SkipBuild,
    [string]$SnapshotDirectory,
    [string]$TestFont
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$app = Join-Path $root 'apps/windows/flclash_ui'
$flutter = if ($FlutterSdk) { Join-Path $FlutterSdk 'bin/flutter.bat' } else { 'flutter' }
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
function Invoke-Flutter {
    & $flutter @args
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed: $args" }
}
$version = (& $flutter --version --machine | Out-String | ConvertFrom-Json).frameworkVersion
if ($LASTEXITCODE -ne 0 -or $version -ne '3.47.6') { throw "Expected Flutter 3.47.6; found $version" }
$oldNoProxy = $env:NO_PROXY
$env:NO_PROXY = (@($oldNoProxy, 'localhost', '127.0.0.1', '::1') | Where-Object { $_ }) -join ','
Push-Location $app
try {
    $pubOutput = & $flutter pub get --offline --enforce-lockfile 2>&1
    $pubCode = $LASTEXITCODE
    $pubOutput | Write-Output
    if ($pubCode -ne 0) {
        if (($pubOutput -join "`n") -notmatch 'symlink|symbolic link') { throw 'Offline dependency restore failed' }
        & (Join-Path $PSScriptRoot 'prepare-flclash-plugins.ps1') -AppRoot $app
        Invoke-Flutter pub get --offline --enforce-lockfile
    }
    & (Join-Path $PSScriptRoot 'prepare-flclash-plugins.ps1') -AppRoot $app
    python (Join-Path $PSScriptRoot 'check-flclash-sources.py')
    if ($LASTEXITCODE -ne 0) { throw 'Source provenance or offline boundary check failed' }
    Invoke-Flutter analyze --no-pub
    $flags = @('--dart-define=SAFE_MODE=true', '--dart-define=FREEV6_OFFLINE=true')
    if ($SnapshotDirectory) {
        $flags += "--dart-define=FREEV6_SNAPSHOTS=$([IO.Path]::GetFullPath($SnapshotDirectory))"
    }
    if ($TestFont) { $flags += "--dart-define=FREEV6_TEST_FONT=$TestFont" }
    Invoke-Flutter test --no-pub test/freev6 @flags
    # Preserve upstream expectations outside the explicit FreeV6 preview flag.
    Invoke-Flutter test --no-pub test/core/controller_test.dart test/widgets/sidebar_test.dart test/widgets/proxies_tab_test.dart test/l10n test/lint/dynamic_message_key_test.dart --dart-define=SAFE_MODE=true
    if (-not $SkipBuild) {
        $exe = Join-Path $app 'build/windows/x64/runner/Release/freev6-flclash-preview.exe'
        $running = Get-Process -Name 'freev6-flclash-preview' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq $exe) }
        if ($running) { throw 'Close the preview from this build directory before rebuilding it' }
        $releaseVersion = (Get-Content (Join-Path $root 'apps/windows/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json).version
        Invoke-Flutter build windows --release --no-pub --target lib/main.dart @flags --build-name=$releaseVersion --build-number=0
        if (-not (Test-Path -LiteralPath $exe)) { throw 'Offline preview executable missing' }
        $binaries = @(Get-ChildItem -LiteralPath (Split-Path $exe) -Filter '*.exe' -Recurse)
        if ($binaries.Count -ne 1 -or $binaries[0].FullName -ine $exe) { throw 'Unexpected executable in offline preview bundle' }
        Write-Output "Offline preview built (not launched or installed): $exe"
    }
} finally { $env:NO_PROXY = $oldNoProxy; Pop-Location }
