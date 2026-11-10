param([string]$FlutterSdk = $env:FREEV6_FLUTTER_SDK, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$flutter = if ($FlutterSdk) { Join-Path $FlutterSdk 'bin/flutter.bat' } else { 'flutter' }
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
function Invoke-Flutter {
    & $flutter @args
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed: $args" }
}
$version = (& $flutter --version --machine | Out-String | ConvertFrom-Json).frameworkVersion
if ($LASTEXITCODE -ne 0 -or $version -ne '3.47.6') { throw "Expected Flutter 3.47.6; found $version" }
$releaseVersion = (Get-Content (Join-Path $root 'apps/windows/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json).version
Push-Location (Join-Path $root 'apps/windows/flutter_ui')
try {
    Invoke-Flutter pub get --enforce-lockfile
    Invoke-Flutter analyze --no-pub
    Invoke-Flutter test --no-pub
    if (-not $SkipBuild) {
        Invoke-Flutter build windows --release --no-pub --build-name=$releaseVersion --build-number=0
        $exe = Join-Path (Get-Location) 'build/windows/x64/runner/Release/freev6-windows-preview.exe'
        if (-not (Test-Path $exe)) { throw 'Preview executable missing' }
        $probe = Start-Process -FilePath $exe -ArgumentList '--host-probe' -PassThru
        if (-not $probe.WaitForExit(30000)) {
            # Only this test-owned process is terminated; never search by name.
            $probe.Kill()
            throw 'Native bridge probe timed out'
        }
        $probe.Refresh()
        if ($probe.ExitCode -ne 0) { throw "Native bridge probe failed: $($probe.ExitCode)" }
        Write-Output "Preview build and native bridge probe passed: $exe"
    }
} finally { Pop-Location }
