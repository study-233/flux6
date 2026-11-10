param([string]$FlutterSdk=$env:FREEV6_FLUTTER_SDK, [switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$app=Join-Path $root 'apps/windows/flclash_ui'
$flutter=if($FlutterSdk){Join-Path $FlutterSdk 'bin/flutter.bat'}else{'flutter'}
function Invoke-Flutter {
    & $flutter @args
    if($LASTEXITCODE -ne 0){throw "Flutter failed: $args"}
}
& (Join-Path $PSScriptRoot 'check-flclash-preview.ps1') -FlutterSdk $FlutterSdk -SkipBuild
Push-Location (Join-Path $root 'apps/windows/flutter_ui')
$oldNoProxy=$env:NO_PROXY
$env:NO_PROXY=(@($oldNoProxy,'localhost','127.0.0.1','::1')|Where-Object{$_}) -join ','
try {
    Invoke-Flutter analyze --no-pub
    Invoke-Flutter test --no-pub
} finally { Pop-Location }
Push-Location $app
try {
    if(-not $SkipBuild){
        $version=(Get-Content (Join-Path $root 'apps/windows/src-tauri/tauri.conf.json') -Raw|ConvertFrom-Json).version
        Invoke-Flutter build windows --release --no-pub --flavor fixture --target lib/fixture_main.dart --dart-define=SAFE_MODE=true --dart-define=FREEV6_OFFLINE=true --build-name=$version --build-number=0
        $exe=Join-Path $app 'build/windows/x64/fixture/runner/Release/freev6-flclash-offline.exe'
        if(-not(Test-Path -LiteralPath $exe)){throw 'Offline backend fixture executable missing'}
        $binaries=@(Get-ChildItem -LiteralPath (Split-Path $exe) -Filter '*.exe' -Recurse)
        if($binaries.Count -ne 1 -or $binaries[0].FullName -ine $exe){throw 'Unexpected executable in offline bundle'}
        $probe=Start-Process -FilePath $exe -ArgumentList '--host-probe' -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
        Write-Output "Owned offline host probe PID: $($probe.Id)"
        if(-not $probe.WaitForExit(30000)){
            $probe.Kill()
            throw 'Owned offline host probe timed out'
        }
        $probe.Refresh()
        if($probe.ExitCode -ne 0){throw "Offline host probe failed: $($probe.ExitCode)"}
        # Compile the real composition root and shared native host without starting either.
        Invoke-Flutter build windows --release --no-pub --flavor live --target lib/live_main.dart --dart-define=FREEV6_BACKEND=true --build-name=$version --build-number=0
        $live=Join-Path $app 'build/windows/x64/live/runner/Release/freev6-desktop.exe'
        if(-not(Test-Path -LiteralPath $live)){throw 'Live compilation output missing'}
        Write-Output "Offline fixture and host probe passed: $exe"
        Write-Output "Live entry compiled only; not launched, installed or bundled with a helper: $live"
    }
} finally {$env:NO_PROXY=$oldNoProxy;Pop-Location}
