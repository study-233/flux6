$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $root
try {
    $directory = 'apps/windows/src-tauri/binaries'
    New-Item -ItemType Directory -Force $directory | Out-Null
    $temporary = "$directory/freev6-helper-x86_64-pc-windows-msvc.build.exe"
    go build -trimpath -buildvcs=false -o $temporary ./cmd/freev6-helper
    if ($LASTEXITCODE -ne 0) { throw 'Go helper build failed' }
    Move-Item -Force $temporary "$directory/freev6-helper-x86_64-pc-windows-msvc.exe"
    go run ./cmd/ensure-geodata
    if ($LASTEXITCODE -ne 0) { throw 'GeoSite preparation failed' }
} finally {
    Pop-Location
}
