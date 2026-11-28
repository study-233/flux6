param([string]$BundleDirectory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $root
try {
    if ($BundleDirectory) {
        $directory = $BundleDirectory
        $name = 'flux6-helper'
    } else {
        $directory = 'apps/windows/src-tauri/binaries'
        $name = 'flux6-helper-x86_64-pc-windows-msvc'
    }
    New-Item -ItemType Directory -Force $directory | Out-Null
    $temporary = Join-Path $directory "$name.build.exe"
    # Corresponding-source archives omit compiled objects, including the version resource.
    $release = Get-Content (Join-Path $root 'apps/windows/release.json') -Raw | ConvertFrom-Json
    $resourceVersion = "$($release.version).$($release.build)"
    if ($BundleDirectory -or -not (Test-Path -LiteralPath 'cmd/freev6-helper/rsrc_windows_amd64.syso')) {
        Push-Location 'cmd/freev6-helper'
        try {
            go run github.com/tc-hib/go-winres@v0.3.3 make --in winres/winres.json --arch amd64 --product-version $resourceVersion --file-version $resourceVersion
            if ($LASTEXITCODE -ne 0) { throw 'Go helper resource generation failed' }
        } finally { Pop-Location }
    }
    go build -trimpath -buildvcs=false -o $temporary ./cmd/freev6-helper
    if ($LASTEXITCODE -ne 0) { throw 'Go helper build failed' }
    $versionInfo = (Get-Item -LiteralPath $temporary).VersionInfo
    if ($versionInfo.FileDescription -cne 'Flux6 Helper' -or $versionInfo.OriginalFilename -cne 'flux6-helper.exe') {
        throw 'Helper version resource is missing or stale. Regenerate it from cmd/freev6-helper/winres/winres.json.'
    }
    Move-Item -Force $temporary (Join-Path $directory "$name.exe")
    go run ./cmd/ensure-geodata
    if ($LASTEXITCODE -ne 0) { throw 'GeoSite preparation failed' }
} finally {
    Pop-Location
}
