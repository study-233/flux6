param([string]$AppRoot = (Join-Path $PSScriptRoot '../../apps/windows/flclash_ui'))
$ErrorActionPreference = 'Stop'
$app = (Resolve-Path -LiteralPath $AppRoot).Path
$metadata = Get-Content -LiteralPath (Join-Path $app '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$links = Join-Path $app 'windows/flutter/ephemeral/.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $links | Out-Null
foreach ($plugin in $metadata.plugins.windows) {
    if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid plugin name' }
    $source = (Resolve-Path -LiteralPath $plugin.path).Path
    $link = Join-Path $links $plugin.name
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if (-not $item.LinkType) { throw "Plugin path is not a link: $link" }
        $target = @($item.Target)[0]
        if ([IO.Path]::GetFullPath($target).TrimEnd('\') -ine $source.TrimEnd('\')) {
            throw "Plugin link target changed: $link"
        }
        continue
    }
    # NTFS junctions work without Developer Mode or administrator privileges.
    New-Item -ItemType Junction -Path $link -Target $source | Out-Null
}
Write-Output "Prepared Windows plugin junctions: $links"
