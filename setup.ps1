#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the scheduled tasks and the event log source.

.DESCRIPTION
    Creates two tasks running as SYSTEM (with Windows PowerShell 5.1 by default,
    -Shell pwsh.exe for PowerShell 7):
      Backup-Run    backup.ps1        daily at -BackupTime
      Backup-Check  check-backup.ps1  daily at -CheckTime
    and the Application event log source "BackupAutomation" used for
    summary events (IDs 1000 OK, 1001 failed targets, 1002 fatal, 1003 check failed).

    Validates config.json first, so a broken config is caught now and not at 2 am.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$BackupTime = '02:00',
    [string]$CheckTime  = '08:00',
    [string]$TaskPath   = '\Backup\',
    [ValidateSet('powershell.exe', 'pwsh.exe')][string]$Shell = 'powershell.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1') -Force

$null = Get-BackupConfig -Path $ConfigPath
Write-Output "Config OK: $ConfigPath"

if (-not ('System.Diagnostics.EventLog' -as [type])) { Add-Type -AssemblyName 'System.Diagnostics.EventLog' }
# .NET API instead of New-EventLog, which does not exist in PowerShell 7
if (-not [System.Diagnostics.EventLog]::SourceExists('BackupAutomation')) {
    if ($PSCmdlet.ShouldProcess('Application log', 'Register event source BackupAutomation')) {
        [System.Diagnostics.EventLog]::CreateEventSource('BackupAutomation', 'Application')
        Write-Output 'Event log source BackupAutomation registered'
    }
}

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$tasks = @(
    @{ Name = 'Backup-Run';   Script = 'backup.ps1';       At = $BackupTime }
    @{ Name = 'Backup-Check'; Script = 'check-backup.ps1'; At = $CheckTime }
)

foreach ($t in $tasks) {
    $scriptPath = Join-Path $PSScriptRoot $t.Script
    $arguments  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $scriptPath, (Resolve-Path $ConfigPath)
    # Without -WorkingDirectory a SYSTEM task starts in C:\Windows\System32.
    $action  = New-ScheduledTaskAction -Execute $Shell -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -Daily -At $t.At

    if ($PSCmdlet.ShouldProcess("$TaskPath$($t.Name)", 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $t.Name -TaskPath $TaskPath -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Output "Scheduled task $TaskPath$($t.Name): $($t.Script) daily at $($t.At)"
    }
}

Write-Output ''
Write-Output 'Next step: store the credentials as SYSTEM, e.g.'
Write-Output "  psexec -s -i powershell.exe -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Set-BackupCredentials.ps1')`""
Write-Output "Test run:  Start-ScheduledTask -TaskPath '$TaskPath' -TaskName 'Backup-Run'"
