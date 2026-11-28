param(
    [string]$FlutterSdk = $env:FREEV6_FLUTTER_SDK,
    [string]$MakeNsis = 'makensis',
    [string]$Python = 'python',
    [switch]$Unified = $true,
    [switch]$NoInstaller,
    [switch]$NoPortable,
    [switch]$OfflinePub,
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
$releaseVersion = Get-Content (Join-Path $root 'apps/windows/release.json') -Raw | ConvertFrom-Json
$version = $releaseVersion.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Windows release version must be numeric x.y.z' }
$variant = if ($Unified) { 'unified' } else { 'flutter' }
$sourceArgs = @(if ($Unified) { '--unified' })
$destination = Join-Path $root "dist/windows/$version-$variant"
function Confirm-ReplaceableCandidate {
    if (-not (Test-Path -LiteralPath $destination)) { return }
    if (-not $Rebuild) { throw "Candidate already exists: $destination. Use -Rebuild for a local unpublished candidate." }
    foreach ($name in @('config','state','runtime')) {
        if (Get-ChildItem -LiteralPath $destination -Recurse -Directory -Filter $name) {
            throw 'Candidate contains runtime data; preserve it before rebuilding.'
        }
    }
}
Confirm-ReplaceableCandidate
$stages = Join-Path $root "build/windows-$variant-package"
$work = Join-Path $stages ([Guid]::NewGuid().ToString('N'))
$bundle = Join-Path $work 'bundle'
$artifacts = Join-Path $work 'artifacts'
New-Item -ItemType Directory -Force $bundle, $artifacts, (Split-Path $destination) | Out-Null
$manifest = Join-Path $work 'source-before.json'
Push-Location $root
$oldPath = $env:PATH
$oldGoos = $env:GOOS; $oldGoarch = $env:GOARCH; $oldCgo = $env:CGO_ENABLED
try {
    Invoke-Checked $Python @('scripts/windows/check-sources.py')
    Invoke-Checked $Python (@('scripts/windows/package-source.py','snapshot','--manifest',$manifest) + $sourceArgs)
    if (-not $SkipChecks) {
        Push-Location $ui
        try {
            Invoke-Checked $flutter @('pub','get','--enforce-lockfile')
            Invoke-Checked $flutter @('analyze','--no-pub')
            Invoke-Checked $flutter @('test','--no-pub','test/backend_test.dart','test/upgrade_and_nodes_test.dart')
        } finally { Pop-Location }
        Invoke-Checked 'go' @('test','-timeout=180s','-run','Test(NetworkOptions|Probe|ProcessWorkingSet|Update|ParseVersionJSON|FetchVersionJSON|Download)','./cmd/freev6-helper')
        Invoke-Checked 'go' @('vet','./cmd/freev6-helper')
    }
    if ($Unified) {
        if ($FlutterSdk) { $env:PATH = (Join-Path (Resolve-Path $FlutterSdk) 'bin') + ';' + $env:PATH }
        $release = $null
        & (Join-Path $root 'scripts/unified/check-windows.ps1') -WindowsClient -Python $Python -OfflinePub:$OfflinePub -SkipChecks:$SkipChecks -LiveReleaseDirectory ([ref]$release)
        if (-not $release) { throw 'Unified build did not produce a live Release directory' }
    } else {
        Push-Location $ui
        try {
            Invoke-Checked $flutter @('pub','get','--enforce-lockfile')
            Invoke-Checked $flutter @('build','windows','--release','--no-pub','--flavor','live','--target','lib/live_main.dart',"--build-name=$version","--build-number=$($releaseVersion.build)")
        } finally { Pop-Location }
        $release = Join-Path $ui 'build/windows/x64/live/runner/Release'
    }
    # Explicit payload selection excludes any runtime data beside a test build.
    Copy-Item (Join-Path $release 'freev6-desktop.exe') $bundle
    Get-ChildItem $release -Filter '*.dll' -File | Copy-Item -Destination $bundle
    Copy-Item (Join-Path $release 'data') $bundle -Recurse
    $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    if ($Unified) {
        Copy-Item (Join-Path $release 'flux6-helper.exe'),(Join-Path $release 'GeoSite.dat') $bundle
    } else {
        & (Join-Path $PSScriptRoot 'build-helper.ps1') -BundleDirectory $bundle
        Copy-Item (Join-Path $root 'GeoSite.dat') $bundle
    }
    Copy-Item (Join-Path $root 'README.md') $bundle
    New-Item -ItemType Directory -Force (Join-Path $bundle 'docs') | Out-Null
    Copy-Item (Join-Path $root 'docs/agreement.md'),(Join-Path $root 'docs/privacy.md') (Join-Path $bundle 'docs')
    Invoke-Checked $Python (@('scripts/windows/package-source.py','prepare','--manifest',$manifest,'--bundle',$bundle) + $sourceArgs)
    $sources = Join-Path $artifacts "Flux6_${version}_windows_${variant}_source.zip"
    Invoke-Checked $Python (@('scripts/windows/package-source.py','archive','--bundle',$bundle,'--output',$sources) + $sourceArgs)
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
        $setup = Join-Path $artifacts "Flux6_${version}_x64_${variant}_setup.exe"
        Invoke-Checked $MakeNsis @('/INPUTCHARSET','UTF8',"/DVERSION=$version","/DREPO=$root","/DBUNDLE=$bundle","/DOUTPUT=$setup","/DUNINSTALL_FILES=$uninstall",(Join-Path $root 'apps/windows/installer/flutter.nsi'))
    }
    if (-not $NoPortable) {
        Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath (Join-Path $artifacts "Flux6_${version}_x64_${variant}_portable.zip")
    }
    if (-not $NoInstaller) {
        $metadata = [ordered]@{
            version = $version; tag = "v$version"; setup = (Split-Path $setup -Leaf)
            notes = "Flux6 Windows $version"
            download = "https://github.com/study-233/flux6/releases/download/v$version/$(Split-Path $setup -Leaf)"
            sha256 = (Get-FileHash $setup).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText((Join-Path $artifacts 'version.json'), ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    $hashes = @(Get-ChildItem $artifacts -File | Sort-Object Name | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name })
    [IO.File]::WriteAllLines((Join-Path $artifacts 'SHA256SUMS'),$hashes,[Text.UTF8Encoding]::new($false))
    # Publish a complete set only; a failed rebuild keeps the previous candidate.
    $lock = [IO.File]::Open((Join-Path $stages 'publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Confirm-ReplaceableCandidate
        $previous = Join-Path $work 'previous'
        if (Test-Path -LiteralPath $destination) { [IO.Directory]::Move($destination, $previous) }
        try { [IO.Directory]::Move($artifacts, $destination) }
        catch {
            if (Test-Path -LiteralPath $previous) { [IO.Directory]::Move($previous, $destination) }
            throw
        }
    } finally { $lock.Dispose() }
    Write-Output "Candidate ready: $destination"
    Write-Output 'Use the candidate in a Windows test environment and follow the native acceptance checklist.'
} finally {
    $env:PATH = $oldPath
    $env:GOOS = $oldGoos; $env:GOARCH = $oldGoarch; $env:CGO_ENABLED = $oldCgo
    Pop-Location
}
