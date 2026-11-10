param(
    [string]$FlutterSdk = $env:FREEV6_FLUTTER_SDK,
    [string]$MakeNsis = 'makensis',
    [string]$Python = 'python',
    [switch]$NoInstaller,
    [switch]$SkipChecks,
    [switch]$Rebuild
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ui = Join-Path $root 'apps/windows/flutter_ui'
$flutter = if ($FlutterSdk) { Join-Path $FlutterSdk 'bin/flutter.bat' } else { 'flutter' }
$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($env:OS -ne 'Windows_NT' -or $nativeArch -ne 'AMD64') { throw 'This build script targets Windows x64. ARM64 is not yet an accepted target.' }
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Program $Arguments" }
}
Invoke-Checked $Python @('--version')
Invoke-Checked 'go' @('version')
if (-not $NoInstaller) { Invoke-Checked $MakeNsis @('/VERSION') }
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
$found = (& $flutter --version --machine | Out-String | ConvertFrom-Json).frameworkVersion
if ($LASTEXITCODE -ne 0 -or $found -ne '3.47.6') { throw "Expected Flutter 3.47.6; found $found" }
$version = (Get-Content (Join-Path $root 'apps/windows/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Windows release version must be numeric x.y.z' }
$destination = Join-Path $root "dist/windows/$version-flutter"
if (Test-Path $destination) {
    if (-not $Rebuild) { throw "Candidate already exists: $destination. Use -Rebuild for a local unpublished candidate." }
    # Never erase data created by a user who launched an old unpacked candidate.
    foreach ($name in @('config','state','runtime')) {
        if (Get-ChildItem $destination -Recurse -Directory -Filter $name) { throw 'Candidate contains runtime data; move it outside the disposable output before rebuilding.' }
    }
    Remove-Item -LiteralPath $destination -Recurse -Force
}
$work = Join-Path $root 'build/windows-flutter-package'
$bundle = Join-Path $work 'bundle'
if (Test-Path $bundle) {
    foreach ($name in @('config','state','runtime')) {
        if (Test-Path (Join-Path $bundle $name)) { throw 'Build staging contains runtime data; preserve it before rebuilding.' }
    }
    Remove-Item -LiteralPath $bundle -Recurse -Force
}
New-Item -ItemType Directory -Force $bundle, $destination | Out-Null
$manifest = Join-Path $work 'source-before.json'
Push-Location $root
$oldGoos = $env:GOOS; $oldGoarch = $env:GOARCH; $oldCgo = $env:CGO_ENABLED
try {
    Invoke-Checked $Python @('scripts/windows/check-sources.py')
    Invoke-Checked $Python @('scripts/windows/package-source.py','snapshot','--manifest',$manifest)
    if (-not $SkipChecks) {
        & (Join-Path $PSScriptRoot 'check-flutter.ps1') -FlutterSdk $FlutterSdk -SkipBuild
        Invoke-Checked 'go' @('test','-timeout=180s','./cmd/freev6-helper','./internal/...')
        Invoke-Checked 'go' @('vet','./cmd/freev6-helper','./internal/...')
    }
    Push-Location $ui
    try {
        Invoke-Checked $flutter @('pub','get','--enforce-lockfile')
        Invoke-Checked $flutter @('build','windows','--release','--no-pub','--flavor','live','--target','lib/live_main.dart',"--build-name=$version",'--build-number=0')
    } finally { Pop-Location }
    $release = Join-Path $ui 'build/windows/x64/live/runner/Release'
    # Explicit payload selection excludes any runtime data beside a test build.
    Copy-Item (Join-Path $release 'freev6-desktop.exe') $bundle
    Get-ChildItem $release -Filter '*.dll' -File | Copy-Item -Destination $bundle
    Copy-Item (Join-Path $release 'data') $bundle -Recurse
    $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    Invoke-Checked 'go' @('build','-trimpath','-buildvcs=false','-o',(Join-Path $bundle 'freev6-helper.exe'),'./cmd/freev6-helper')
    Invoke-Checked 'go' @('run','./cmd/ensure-geodata')
    Copy-Item (Join-Path $root 'GeoSite.dat') $bundle
    Copy-Item (Join-Path $root 'README.md') $bundle
    New-Item -ItemType Directory -Force (Join-Path $bundle 'docs') | Out-Null
    Copy-Item (Join-Path $root 'docs/agreement.md'),(Join-Path $root 'docs/privacy.md') (Join-Path $bundle 'docs')
    Invoke-Checked $Python @('scripts/windows/package-source.py','prepare','--manifest',$manifest,'--bundle',$bundle)
    $sources = Join-Path $destination "FreeV6_${version}_windows_flutter_source.zip"
    Invoke-Checked $Python @('scripts/windows/package-source.py','archive','--bundle',$bundle,'--output',$sources)
    if (-not $NoInstaller) {
        $uninstall = Join-Path $work 'uninstall-files.nsh'
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem $bundle -Recurse -File) {
            $relative = $file.FullName.Substring($bundle.Length + 1).Replace('$','$$')
            $lines.Add('Delete "$INSTDIR\' + $relative + '"')
        }
        foreach ($dir in Get-ChildItem $bundle -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending) {
            $relative = $dir.FullName.Substring($bundle.Length + 1).Replace('$','$$')
            $lines.Add('RMDir "$INSTDIR\' + $relative + '"')
        }
        [IO.File]::WriteAllLines($uninstall,$lines,[Text.UTF8Encoding]::new($true))
        $setup = Join-Path $destination "FreeV6_${version}_x64_flutter_setup.exe"
        Invoke-Checked $MakeNsis @('/INPUTCHARSET','UTF8',"/DVERSION=$version","/DREPO=$root","/DBUNDLE=$bundle","/DOUTPUT=$setup","/DUNINSTALL_FILES=$uninstall",(Join-Path $root 'apps/windows/installer/flutter.nsi'))
    }
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath (Join-Path $destination "FreeV6_${version}_x64_flutter_portable.zip")
    $hashes = @(Get-ChildItem $destination -File | Sort-Object Name | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name })
    [IO.File]::WriteAllLines((Join-Path $destination 'SHA256SUMS'),$hashes,[Text.UTF8Encoding]::new($false))
    Write-Output "Candidate ready: $destination"
    Write-Output 'No application or proxy was launched. Install on the Windows test machine and follow the acceptance checklist.'
} finally {
    $env:GOOS = $oldGoos; $env:GOARCH = $oldGoarch; $env:CGO_ENABLED = $oldCgo
    Pop-Location
}
