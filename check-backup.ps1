#Requires -Version 5.1
<#
.SYNOPSIS
    Independent health check: is the newest backup of every target fresh, non-empty and
    intact - locally and in the offsite store?

.DESCRIPTION
    Runs separately from backup.ps1 (setup.ps1 schedules it a few hours later), so it
    also catches the case where the backup task did not run at all.

    Checks per target:
      VMware   newest <BackupPath>/<VM>/<timestamp> folder contains a non-empty .ovf(.enc)
      FireBird newest <Name>_<timestamp>.fbk(.enc) exists and is not empty
      Oracle   newest <Label>_<timestamp>.dmp(.enc) exists and is not empty
    and that the newest copy is younger than Monitoring.MaxBackupAgeHours.

    Monitoring.VerifyChecksums (default true): every file of the newest local set is
    re-hashed against its SHA256 manifest, which detects silent corruption (bad sectors,
    a broken RAID, an overwritten file). This reads the whole newest backup.

    With Offsite enabled the same checks run against the offsite store (Offsite.Check,
    default true). Re-hashing offsite copies over the network is off by default
    (Monitoring.VerifyOffsiteChecksums) - every copy is already verified on arrival.

    Exit code 0 = all fresh, 1 = problems found, 2 = config error.
    With -AsJson the result is printed as JSON, e.g. for a Zabbix UserParameter.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$AsJson,
    [switch]$NoAlert
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1') -Force

try {
    $config = Get-BackupConfig -Path $ConfigPath
}
catch {
    if ($AsJson) { [pscustomobject]@{ status = 'error'; problems = @($_.Exception.Message) } | ConvertTo-Json -Compress }
    else { Write-Output "CONFIG ERROR: $($_.Exception.Message)" }
    exit 2
}

$monitoring      = Get-ConfigValue -Object $config -Name 'Monitoring'
$maxAge          = [double]$monitoring.MaxBackupAgeHours
$verifyLocal     = [bool](Get-ConfigValue -Object $monitoring -Name 'VerifyChecksums' -Default $true)
$verifyOffsite   = [bool](Get-ConfigValue -Object $monitoring -Name 'VerifyOffsiteChecksums' -Default $false)
$credStore       = Get-ConfigValue -Object $config -Name 'CredentialStorePath' -Default (Join-Path $PSScriptRoot 'secrets')
$offsiteEnabled  = (Test-ComponentEnabled -Config $config -Name 'Offsite') -and
                   [bool](Get-ConfigValue -Object $config.Offsite -Name 'Check' -Default $true)

# One entry per target: where the local copies are and how they look.
$targets = New-Object System.Collections.Generic.List[hashtable]
if (Test-ComponentEnabled -Config $config -Name 'VMware') {
    foreach ($vm in $config.VMware.VirtualMachines) {
        $targets.Add(@{ Component = 'VMware'; Target = $vm; Path = (Join-Path $config.VMware.BackupPath $vm)
                        Set = @{ Directory = $true }; Pattern = @('*.ovf', '*.ovf.enc') })
    }
}
if (Test-ComponentEnabled -Config $config -Name 'FireBird') {
    foreach ($db in $config.FireBird.Databases) {
        $targets.Add(@{ Component = 'FireBird'; Target = $db.Name; Path = $config.FireBird.BackupPath
                        Set = @{ Prefix = $db.Name }; Pattern = @('*.fbk', '*.fbk.enc') })
    }
}
if (Test-ComponentEnabled -Config $config -Name 'Oracle') {
    $ora = $config.Oracle
    $targets.Add(@{ Component = 'Oracle'; Target = $ora.Label; Path = $ora.BackupPath
                    Set = @{ Prefix = $ora.Label }; Pattern = @('*.dmp', '*.dmp.enc') })
}

$checked  = 0
$problems = New-Object System.Collections.Generic.List[string]

foreach ($t in $targets) {
    $checked++
    $setArgs = $t.Set
    $problem = Test-BackupFreshness -Path $t.Path @setArgs -MaxAgeHours $maxAge -Label "$($t.Component)/$($t.Target)" `
        -RequiredPattern $t.Pattern -VerifyChecksums:$verifyLocal
    if ($problem) { $problems.Add($problem) }
}

if ($offsiteEnabled) {
    $offsiteReachable = $true
    try { Connect-OffsiteStore -Config $config -StorePath $credStore }
    catch {
        $offsiteReachable = $false
        $problems.Add("Offsite: $($_.Exception.Message)")
    }
    if ($offsiteReachable) {
        try {
            foreach ($t in $targets) {
                $checked++
                $setArgs = $t.Set
                $offPath = Get-OffsitePath -Config $config -Component $t.Component -Target $t.Target
                $problem = Test-BackupFreshness -Path $offPath @setArgs -MaxAgeHours $maxAge -Label "Offsite/$($t.Component)/$($t.Target)" `
                    -RequiredPattern $t.Pattern -VerifyChecksums:$verifyOffsite
                if ($problem) { $problems.Add($problem) }
            }
        }
        finally {
            Disconnect-OffsiteStore
        }
    }
}

if ($AsJson) {
    [pscustomobject]@{
        status   = if ($problems.Count -gt 0) { 'fail' } else { 'ok' }
        checked  = $checked
        problems = @($problems)
    } | ConvertTo-Json -Compress
}
elseif ($problems.Count -gt 0) {
    Write-Output "BACKUP CHECK FAILED ($($problems.Count) of $checked):"
    $problems | ForEach-Object { Write-Output "  - $_" }
}
else {
    Write-Output "All $checked backups are fresh (limit ${maxAge}h)"
}

if ($problems.Count -gt 0) {
    $message = "Backup check FAILED:`n" + (($problems | ForEach-Object { "- $_" }) -join "`n")
    Write-BackupEvent -Message $message -EntryType Error -EventId 1003
    if (-not $NoAlert) { Send-TelegramAlert -Config $config -Message $message -StorePath $credStore }
    exit 1
}
exit 0
