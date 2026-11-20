$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$candidate = python (Join-Path $root 'scripts/unified/prepare.py')
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare unified candidate' }
Push-Location $candidate
try {
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Locked dependency preparation failed' }
    flutter analyze --no-pub --no-fatal-infos
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    flutter test --no-pub test/unified_node_groups_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Shared node page test failed' }
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows x64 build failed' }
    Get-Item 'build/windows/x64/runner/Release/flux6-unified-preview.exe'
} finally {
    Pop-Location
}
