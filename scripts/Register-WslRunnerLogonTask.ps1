# Registers a Windows Scheduled Task that keeps WSL Arch (and its systemd-managed
# GitHub Actions runner) up at user logon, with a watchdog to restart if needed.
# Run from any PowerShell prompt; will self-elevate via schtasks if required.

[CmdletBinding()]
param(
    [string]$TaskName = 'WSL Arch GitHub Runner',
    [string]$Distro   = 'Arch',
    [string]$ServiceName = 'actions.runner.deepongi-labs-android14-6.1.162-common-2026-03.pixel8-wsl.service'
)

$ErrorActionPreference = 'Stop'

# Action: launch the WSL distro once at logon. WSL2 idle shutdown is disabled via
# %USERPROFILE%\.wslconfig (vmIdleTimeout=-1), so the VM and the systemd-managed
# runner service stay resident until reboot. We deliberately do NOT loop or call
# `systemctl start` repeatedly; restarting the runner service mid-job cancels jobs.
$wslExe = Join-Path $env:WINDIR 'System32\wsl.exe'
$cmd = "systemctl is-active $ServiceName >/dev/null 2>&1 || sudo systemctl start $ServiceName; exec sleep infinity"

$argument = "-d $Distro -u root -- bash -lc `"$cmd`""

$action = New-ScheduledTaskAction -Execute $wslExe -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Keeps WSL Arch online so the GitHub Actions self-hosted runner stays connected.' | Out-Null

Write-Host "Registered scheduled task '$TaskName' for user $env:USERNAME"
schtasks /Query /TN "$TaskName" /V /FO LIST | Select-String -Pattern 'TaskName|Status|Next Run Time|Run As User|Logon Type'
