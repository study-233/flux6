# Read-only inventory; never reads the contents of credentials or WebView data.
param([string]$Output)
$ErrorActionPreference = 'Stop'
$entries = @()
foreach ($registry in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $entries += @(Get-ItemProperty $registry -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'FreeV6' -or $_.DisplayName -eq 'freev6' } |
        Select-Object PSChildName, DisplayName, DisplayVersion, InstallLocation, UninstallString)
}
$result = [ordered]@{
    schemaVersion = 1
    os = [Environment]::OSVersion.VersionString
    architecture = $env:PROCESSOR_ARCHITECTURE
    installations = $entries
    profileCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'dev.freev6.desktop'),
        (Join-Path $env:APPDATA 'dev.freev6.desktop')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}
$json = $result | ConvertTo-Json -Depth 5
if ($Output) { [IO.File]::WriteAllText($Output, $json, [Text.UTF8Encoding]::new($false)) }
else { Write-Output $json }
