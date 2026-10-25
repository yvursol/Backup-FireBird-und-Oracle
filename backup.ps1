#Requires -Version 5.1
<#
.SYNOPSIS
    Runs all configured backups (VMware, FireBird, Oracle), applies retention, copies the
    new backups offsite and reports.

.DESCRIPTION
    Every target (VM / database) is backed up independently; one failure does not stop
    the others. Per target:
      1. backup (+ test restore / dump verification, encryption, SHA256 manifest)
      2. local retention        - only if step 1 succeeded, keeps Retention.MinKeep copies
      3. offsite copy           - only if step 1 succeeded; copied set is re-verified there
      4. offsite retention      - only if step 3 succeeded, keeps Offsite.Retention.MinKeep

    Exit codes:
      0  all targets succeeded
      1  at least one target (or offsite copy) failed (details in the log, Telegram, event log)
      2  fatal error before any backup ran (invalid config, not enough disk space,
         missing encryption passphrase, ...)

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to this script.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1') -Force

$results = New-Object System.Collections.Generic.List[object]

function Invoke-BackupTarget {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $started = Get-Date
    Write-BackupLog "$Component/${Target}: started"
    try {
        # 3>&1 folds warnings (e.g. failed clone cleanup) into the stream so they reach the log
        $all    = @(& $Action 3>&1)
        $output = @($all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
            ForEach-Object { Write-BackupLog "$Component/${Target}: $($_.Message)" -Level WARN }
        $duration = ((Get-Date) - $started).ToString('hh\:mm\:ss')
        $last     = $output | Select-Object -Last 1
        $detail   = if ($last) { ($last.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' } else { '' }
        Write-BackupLog "$Component/${Target}: OK in $duration ($detail)"
        $results.Add([pscustomobject]@{ Component = $Component; Target = $Target; Success = $true; Error = $null })
    }
    catch {
        Write-BackupLog "$Component/${Target}: FAILED - $($_.Exception.Message)" -Level ERROR
        Write-BackupLog "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -Level ERROR
        $results.Add([pscustomobject]@{ Component = $Component; Target = $Target; Success = $false; Error = $_.Exception.Message })
    }
}

function Test-TargetSucceeded([string]$Component, [string]$Target) {
    @($results | Where-Object { $_.Component -eq $Component -and $_.Target -eq $Target -and $_.Success }).Count -gt 0
}

function Invoke-Retention {
    param([string]$Component, [string]$Target, [hashtable]$SetArgs, [int]$Days, [int]$MinKeep)
    if (-not (Test-TargetSucceeded $Component $Target)) {
        Write-BackupLog "$Component/${Target}: retention skipped because this run failed" -Level WARN
        return
    }
    try {
        $removed = @(Remove-ExpiredBackup @SetArgs -RetentionDays $Days -MinKeep $MinKeep)
        foreach ($r in $removed) { Write-BackupLog "$Component/${Target}: retention removed $r" }
    }
    catch {
        Write-BackupLog "$Component/${Target}: retention failed - $($_.Exception.Message)" -Level ERROR
        $results.Add([pscustomobject]@{ Component = $Component; Target = "$Target (retention)"; Success = $false; Error = $_.Exception.Message })
    }
}

function Invoke-OffsiteStep {
    # Local retention, then (if enabled) copy to the offsite store and offsite retention.
    param([string]$Component, [string]$Target, [hashtable]$SetArgs, [string]$OffsitePath)

    Invoke-Retention -Component $Component -Target $Target -SetArgs $SetArgs -Days $retentionDays -MinKeep $retentionMinKeep
    if (-not $offsiteEnabled) { return }

    $offTarget = "$Target (offsite)"
    if (-not (Test-TargetSucceeded $Component $Target)) {
        Write-BackupLog "$Component/${offTarget}: skipped because the backup failed" -Level WARN
        return
    }
    Invoke-BackupTarget -Component $Component -Target $offTarget -Action {
        if (-not $script:offsiteConnected) {
            Connect-OffsiteStore -Config $config -StorePath $credStore
            $script:offsiteConnected = $true
        }
        Copy-BackupSetToOffsite @SetArgs -Destination $OffsitePath -MinFreeSpaceGB $offsiteMinFree
    }
    $offArgs = $SetArgs.Clone()
    $offArgs.Path = $OffsitePath
    Invoke-Retention -Component $Component -Target $offTarget -SetArgs $offArgs -Days $offsiteDays -MinKeep $offsiteMinKeep
}

# ---------------------------------------------------------------- setup
try {
    $config    = Get-BackupConfig -Path $ConfigPath
    $logDir    = Get-ConfigValue -Object $config -Name 'LogPath' -Default (Join-Path $PSScriptRoot 'logs')
    $credStore = Get-ConfigValue -Object $config -Name 'CredentialStorePath' -Default (Join-Path $PSScriptRoot 'secrets')
    Initialize-BackupLog -Directory $logDir -Name 'backup' | Out-Null
    Write-BackupLog '=== Backup run started ==='

    $retentionDays    = [int]$config.Retention.Days
    $retentionMinKeep = [int]$config.Retention.MinKeep

    # Options passed to every backup worker
    $workerArgs = @{ MinFreeSpaceGB = [double]$config.MinFreeSpaceGB }
    if (Test-ComponentEnabled -Config $config -Name 'Encryption') {
        # Fail the whole run rather than silently writing unencrypted backups.
        $workerArgs.EncryptionCredential = Get-BackupCredential -Name $config.Encryption.CredentialName -StorePath $credStore
        $workerArgs.EncryptionIterations = [int](Get-ConfigValue -Object $config.Encryption -Name 'Iterations' -Default 600000)
        Write-BackupLog 'Encryption: enabled (AES-256)'
    }

    $offsiteEnabled = Test-ComponentEnabled -Config $config -Name 'Offsite'
    $script:offsiteConnected = $false
    if ($offsiteEnabled) {
        $offRetention   = Get-ConfigValue -Object $config.Offsite -Name 'Retention'
        $offsiteDays    = [int](Get-ConfigValue -Object $offRetention -Name 'Days' -Default $retentionDays)
        $offsiteMinKeep = [int](Get-ConfigValue -Object $offRetention -Name 'MinKeep' -Default $retentionMinKeep)
        $offsiteMinFree = [double](Get-ConfigValue -Object $config.Offsite -Name 'MinFreeSpaceGB' -Default 0)
        Write-BackupLog "Offsite: $($config.Offsite.Path)"
    }

    $backupPaths = @()
    if (Test-ComponentEnabled -Config $config -Name 'VMware')   { $backupPaths += $config.VMware.BackupPath }
    if (Test-ComponentEnabled -Config $config -Name 'FireBird') { $backupPaths += $config.FireBird.BackupPath }
    if (Test-ComponentEnabled -Config $config -Name 'Oracle')   { $backupPaths += $config.Oracle.BackupPath }

    # Quick sanity check before anything starts. Each worker checks again before every
    # step that writes data, with an estimate of what that step needs.
    foreach ($path in $backupPaths) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $free = Get-FreeSpaceGB -Path $path
        if ($free -lt $config.MinFreeSpaceGB) {
            throw "Not enough free space for $path`: ${free}GB free, MinFreeSpaceGB is $($config.MinFreeSpaceGB)"
        }
        Write-BackupLog "Free space for ${path}: ${free}GB"
    }
}
catch {
    $message = "Backup aborted: $($_.Exception.Message)"
    Write-BackupLog $message -Level ERROR
    Write-BackupEvent -Message $message -EntryType Error -EventId 1002
    if (Get-Variable config -ErrorAction SilentlyContinue) {
        Send-TelegramAlert -Config $config -Message $message -StorePath $credStore
    }
    exit 2
}

# Anything below that escapes the per-target error handling is a bug or an
# environment problem - report it instead of dying silently.
try {
    # ---------------------------------------------------------------- VMware
    if (Test-ComponentEnabled -Config $config -Name 'VMware') {
        $vmw = $config.VMware
        $connected = $false
        try {
            Import-Module VMware.VimAutomation.Core
            if (Get-ConfigValue -Object $vmw -Name 'IgnoreInvalidCertificate' -Default $false) {
                Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
            }
            $cred = Get-BackupCredential -Name $vmw.CredentialName -StorePath $credStore
            Connect-VIServer -Server $vmw.VCenter -Credential $cred | Out-Null
            $connected = $true
        }
        catch {
            Write-BackupLog "VMware: cannot connect to $($vmw.VCenter): $($_.Exception.Message)" -Level ERROR
            foreach ($vmName in $vmw.VirtualMachines) {
                $results.Add([pscustomobject]@{ Component = 'VMware'; Target = $vmName; Success = $false; Error = 'vCenter connection failed' })
            }
        }

        if ($connected) {
            try {
                foreach ($vmName in $vmw.VirtualMachines) {
                    Invoke-BackupTarget -Component 'VMware' -Target $vmName -Action {
                        & (Join-Path $PSScriptRoot 'vmware-backup.ps1') -VMName $vmName -BackupPath $vmw.BackupPath `
                            -Quiesce ([bool](Get-ConfigValue -Object $vmw -Name 'Quiesce' -Default $true)) @workerArgs
                    }
                    Invoke-OffsiteStep -Component 'VMware' -Target $vmName `
                        -SetArgs @{ Path = (Join-Path $vmw.BackupPath $vmName); Directory = $true } `
                        -OffsitePath $(if ($offsiteEnabled) { Get-OffsitePath -Config $config -Component 'VMware' -Target $vmName } else { '' })
                }
            }
            finally {
                Disconnect-VIServer -Server $vmw.VCenter -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    # ---------------------------------------------------------------- FireBird
    if (Test-ComponentEnabled -Config $config -Name 'FireBird') {
        $fb = $config.FireBird
        foreach ($db in $fb.Databases) {
            Invoke-BackupTarget -Component 'FireBird' -Target $db.Name -Action {
                $cred = Get-BackupCredential -Name $db.CredentialName -StorePath $credStore
                & (Join-Path $PSScriptRoot 'firebird-backup.ps1') -Name $db.Name -DatabasePath $db.Path `
                    -BackupPath $fb.BackupPath -GbakPath $fb.GbakPath -Credential $cred -LogDirectory $logDir `
                    -VerifyRestore ([bool](Get-ConfigValue -Object $fb -Name 'VerifyRestore' -Default $true)) @workerArgs
            }
            Invoke-OffsiteStep -Component 'FireBird' -Target $db.Name `
                -SetArgs @{ Path = $fb.BackupPath; Prefix = $db.Name } `
                -OffsitePath $(if ($offsiteEnabled) { Get-OffsitePath -Config $config -Component 'FireBird' } else { '' })
        }
    }

    # ---------------------------------------------------------------- Oracle
    if (Test-ComponentEnabled -Config $config -Name 'Oracle') {
        $ora = $config.Oracle
        Invoke-BackupTarget -Component 'Oracle' -Target $ora.Label -Action {
            $oraArgs = @{
                Label             = $ora.Label
                TnsName           = $ora.TnsName
                DirectoryObject   = $ora.DirectoryObject
                DumpDirectoryPath = $ora.DumpDirectoryPath
                BackupPath        = $ora.BackupPath
                LogDirectory      = $logDir
                Schemas           = @(Get-ConfigValue -Object $ora -Name 'Schemas' -Default @())
                Compression       = Get-ConfigValue -Object $ora -Name 'Compression' -Default 'METADATA_ONLY'
                ExpdpPath         = Get-ConfigValue -Object $ora -Name 'ExpdpPath' -Default 'expdp'
                ImpdpPath         = Get-ConfigValue -Object $ora -Name 'ImpdpPath' -Default 'impdp'
                VerifyDump        = [bool](Get-ConfigValue -Object $ora -Name 'VerifyDump' -Default $true)
                UseWallet         = [bool](Get-ConfigValue -Object $ora -Name 'UseWallet' -Default $false)
            }
            if (-not $oraArgs.UseWallet) {
                $oraArgs.Credential = Get-BackupCredential -Name $ora.CredentialName -StorePath $credStore
            }
            & (Join-Path $PSScriptRoot 'oracle-backup.ps1') @oraArgs @workerArgs
        }
        Invoke-OffsiteStep -Component 'Oracle' -Target $ora.Label `
            -SetArgs @{ Path = $ora.BackupPath; Prefix = $ora.Label } `
            -OffsitePath $(if ($offsiteEnabled) { Get-OffsitePath -Config $config -Component 'Oracle' } else { '' })
    }

    # ---------------------------------------------------------------- summary
    if ($script:offsiteConnected) { Disconnect-OffsiteStore }
    Remove-OldLog -Directory $logDir -Days ([int](Get-ConfigValue -Object $config -Name 'LogRetentionDays' -Default 90))

    $failed  = @($results | Where-Object { -not $_.Success })
    $backups = @($results | Where-Object { $_.Target -notlike '* (offsite)' -and $_.Target -notlike '* (retention)' })
    $summary = '{0} of {1} backups succeeded' -f @($backups | Where-Object { $_.Success }).Count, $backups.Count
    if ($offsiteEnabled) {
        $copies = @($results | Where-Object { $_.Target -like '* (offsite)' })
        $summary += ', {0} of {1} offsite copies' -f @($copies | Where-Object { $_.Success }).Count, $copies.Count
    }

    if ($failed.Count -gt 0) {
        $lines = @($failed | ForEach-Object { "- $($_.Component)/$($_.Target): $($_.Error)" })
        $message = "Backup FAILED: $summary`n" + ($lines -join "`n")
        Write-BackupLog $message -Level ERROR
        Write-BackupEvent -Message $message -EntryType Error -EventId 1001
        Send-TelegramAlert -Config $config -Message $message -StorePath $credStore
        Write-BackupLog '=== Backup run finished with errors ==='
        exit 1
    }

    Write-BackupLog "=== Backup run finished: $summary ==="
    Write-BackupEvent -Message "Backup OK: $summary" -EntryType Information -EventId 1000
    if (Get-ConfigValue -Object (Get-ConfigValue -Object $config -Name 'Telegram') -Name 'NotifyOnSuccess' -Default $false) {
        Send-TelegramAlert -Config $config -Message "Backup OK: $summary" -StorePath $credStore
    }
    exit 0
}
catch {
    $message = "Backup run crashed: $($_.Exception.Message) at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    Write-BackupLog $message -Level ERROR
    Write-BackupEvent -Message $message -EntryType Error -EventId 1002
    Send-TelegramAlert -Config $config -Message $message -StorePath $credStore
    exit 2
}
