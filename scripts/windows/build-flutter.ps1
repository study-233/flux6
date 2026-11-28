param(
    [string]$FlutterSdk = $env:FREEV6_FLUTTER_SDK,
    [string]$MakeNsis = 'makensis',
    [string]$Python = 'python',
    [switch]$NoInstaller,
    [switch]$NoPortable,
    [switch]$OfflinePub,
    [switch]$SkipChecks
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$project = Join-Path $root 'apps/android'
$flutter = if ($FlutterSdk) { Join-Path $FlutterSdk 'bin/flutter.bat' } else { 'flutter' }
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program exited with $LASTEXITCODE" }
}
$release = Get-Content (Join-Path $root 'apps/windows/release.json') -Raw | ConvertFrom-Json
$version = $release.version
$stage = Join-Path $root ('build/windows-' + [Guid]::NewGuid())
$output = Join-Path $stage 'artifacts'
$destination = Join-Path $root "dist/windows/$version-unified"
if (Test-Path $destination) { throw "Release already exists at $destination" }
New-Item -ItemType Directory -Force $output | Out-Null
Push-Location $project
try {
    $sdk = (& $flutter --version --machine | Out-String | ConvertFrom-Json).frameworkVersion
    if ($sdk -ne '3.50.1') { throw "Expected Flutter 3.50.1, found $sdk" }
    $pub = @('pub', 'get', '--enforce-lockfile')
    if ($OfflinePub) { $pub += '--offline' }
    Invoke-Checked $flutter $pub
    if (-not $SkipChecks) {
        Invoke-Checked $flutter @('analyze','--no-pub','--no-fatal-infos')
        Invoke-Checked $flutter @('test','--no-pub','test/common/freev6_test.dart','test/common/release_reset_test.dart','test/common/warp_setup_test.dart','test/core/protocol_contract_test.dart')
    }
    Invoke-Checked $flutter @('build','windows','--release','--no-pub','--dart-define=APP_ENV=stable',"--build-name=$version","--build-number=$($release.build)")
    $bundle = Join-Path $project 'build/windows/x64/runner/Release'
    foreach ($required in @('freev6-desktop.exe','FlClashCore.exe','Flux6HelperService.exe','manifest.json','data/app.so')) {
        if (-not (Test-Path (Join-Path $bundle $required) -PathType Leaf)) { throw "Missing $required" }
    }
    if (-not $SkipChecks) {
        $env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = $bundle
        Invoke-Checked $flutter @('test','--no-pub','--dart-define=FLUX6_NATIVE_SMOKE=true','test/integration/desktop_profile_test.dart')
    }
    $manifest = Get-Content (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
    if ((Get-FileHash (Join-Path $bundle 'FlClashCore.exe')).Hash -ine $manifest.coreSha256) {
        throw 'Packaged core does not match the helper manifest'
    }
    Copy-Item (Join-Path $project 'LICENSE') (Join-Path $bundle 'LICENSE-FlClash')
    Copy-Item (Join-Path $root 'third_party/licenses') (Join-Path $bundle 'licenses') -Recurse
    Copy-Item (Join-Path $project 'plugins/prism_ui/LICENSE') (Join-Path $bundle 'licenses/Prism-LICENSE')
    Copy-Item (Join-Path $project 'plugins/prism_ui/NOTICE') (Join-Path $bundle 'licenses/Prism-NOTICE')
    Copy-Item (Join-Path $project 'core/Clash.Meta/LICENSE') (Join-Path $bundle 'licenses/Mihomo-LICENSE')
    if (-not $NoPortable) {
        Compress-Archive (Join-Path $bundle '*') (Join-Path $output "Flux6-$version-windows-amd64.zip")
    }
    if (-not $NoInstaller) {
        $uninstall = Join-Path $stage 'uninstall-files.nsh'
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
        $setup = Join-Path $output "Flux6-$version-windows-amd64-setup.exe"
        Invoke-Checked $MakeNsis @('/INPUTCHARSET','UTF8',"/DVERSION=$version","/DREPO=$root","/DBUNDLE=$bundle","/DOUTPUT=$setup","/DUNINSTALL_FILES=$uninstall",(Join-Path $root 'apps/windows/installer/flutter.nsi'))
        $metadata = @{ version=$version; tag="v$version"; setup=(Split-Path $setup -Leaf); notes="Flux6 $version"; sha256=(Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant() }
        [IO.File]::WriteAllText((Join-Path $output 'version.json'),($metadata | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    Invoke-Checked git @('-C',$root,'archive','--format=zip','--prefix=Flux6/',"--output=$(Join-Path $output "Flux6-$version-source.zip")",'HEAD')
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    [IO.Directory]::Move($output,$destination)
    Write-Output $destination
} finally { Pop-Location }
