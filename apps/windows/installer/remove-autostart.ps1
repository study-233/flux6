# Remove only autostart entries whose executable belongs to this installation.
param([Parameter(Mandatory=$true)][string]$InstallRoot)
$ErrorActionPreference = 'Stop'
try {
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $desktop = Join-Path $root 'freev6-desktop.exe'
    $helper = Join-Path $root 'freev6-helper.exe'
    $owned = $false
    $task = Get-ScheduledTask -TaskName 'FreeV6 Autostart' -ErrorAction SilentlyContinue
    if ($task) {
        $actions = @($task.Actions)
        if ($actions.Count -eq 1 -and $actions[0].Execute.Trim('"') -ieq $desktop) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
            $owned = $true
        }
    }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $entry = Get-ItemPropertyValue -Path $key -Name 'FreeV6' -ErrorAction SilentlyContinue
    if ($entry -and ($entry.StartsWith('"' + $helper + '"', [StringComparison]::OrdinalIgnoreCase) -or
                    $entry.StartsWith('"' + $desktop + '"', [StringComparison]::OrdinalIgnoreCase))) {
        Remove-ItemProperty -Path $key -Name 'FreeV6'
        $owned = $true
    }
    if ($owned) {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'FreeV6' -ErrorAction SilentlyContinue
    }
    exit 0
} catch { Write-Output 'Could not remove this installation autostart entry.'; exit 20 }
