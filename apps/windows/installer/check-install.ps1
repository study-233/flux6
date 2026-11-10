# Exit 0: no application-owned process uses the target directory.
# Read-only: never kills a process or restores networking inside an installer.
param([Parameter(Mandatory=$true)][string]$InstallRoot)
$ErrorActionPreference = 'Stop'
try {
    $target = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $processes) {
        if ($process.ExecutablePath -and $process.ProcessId -ne $PID) {
            $path = [IO.Path]::GetFullPath($process.ExecutablePath)
            if ($path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) -and
                ([IO.Path]::GetFileName($path) -match '^(freev6-desktop|freev6-helper|mihomo.*)\.exe$')) {
                Write-Output 'Flux6 or its network core is still running. Exit from the tray first.'
                exit 10
            }
        }
    }
    exit 0
} catch {
    Write-Output 'Unable to inspect running application processes. Installation was stopped.'
    exit 20
}
