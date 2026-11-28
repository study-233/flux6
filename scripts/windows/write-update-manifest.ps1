param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Installer
)
$ErrorActionPreference = 'Stop'
$setup = Get-Item -LiteralPath $Installer
$repository = 'https://github.com/study-233/flux6'
$tag = "v$Version"
$metadata = [ordered]@{
    version = $Version
    tag = $tag
    setup = $setup.Name
    notes = "Flux6 $Version"
    download = "$repository/releases/download/$tag/$([Uri]::EscapeDataString($setup.Name))"
    sha256 = (Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$path = Join-Path $setup.DirectoryName 'version.json'
[IO.File]::WriteAllText($path, ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
