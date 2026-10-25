#Requires -Version 5.1
<#
.SYNOPSIS
    Exports one VMware VM to OVF without shutting it down.

.DESCRIPTION
    Export-VApp only works on powered-off VMs. For a running VM the script:
      1. takes a temporary snapshot (quiesced through VMware Tools by default),
      2. creates a linked clone from that snapshot (powered off, no extra disk copy),
      3. exports the clone to OVF,
      4. removes the clone and the snapshot - also when the export fails.
    Powered-off VMs are exported directly.

    The VM name must identify exactly one VM in the connected vCenter. Names are only
    unique per folder, so two datacenters can each have an "app01"; the script then
    stops instead of guessing which one to export.

    Linked clones need vCenter (not a standalone ESXi host).
    Expects an existing PowerCLI session (Connect-VIServer), see backup.ps1.

    The export is written to <BackupPath>/<VM>/.<timestamp>. After the export every file
    is (optionally) encrypted and a SHA256SUMS manifest is written; only then the folder
    is renamed to <BackupPath>/<VM>/<timestamp>, so a failed export is never counted as
    a valid copy by retention or check-backup.ps1.

.OUTPUTS
    PSCustomObject with Path, SizeMB, Mode ('direct' or 'linked-clone'), Encrypted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$BackupPath,
    [bool]$Quiesce = $true,
    # Passphrase for backup encryption; no encryption when omitted.
    [System.Management.Automation.PSCredential]$EncryptionCredential,
    [int]$EncryptionIterations = 600000,
    # Free space that must remain on the backup volume after the export.
    [double]$MinFreeSpaceGB = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1')

$timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$vmDir       = Join-Path $BackupPath $VMName
$finalDir    = Join-Path $vmDir $timestamp
$partialDir  = Join-Path $vmDir ".$timestamp"

# Get-VM -Name accepts wildcards and returns every match in every datacenter.
$found = @(Get-VM -Name $VMName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $VMName })
if ($found.Count -eq 0) { throw "VM '$VMName' not found in vCenter" }
if ($found.Count -gt 1) {
    $where = ($found | ForEach-Object { "host $($_.VMHost)" }) -join ', '
    throw "VM name '$VMName' is ambiguous: $($found.Count) VMs have this name ($where). Rename them so that every VM in VMware.VirtualMachines is unique."
}
$vm = $found[0]

# Thin disks export roughly at their used size; UsedSpaceGB (incl. snapshots and swap)
# errs on the safe side.
$usedGB = [double](Get-ConfigValue -Object $vm -Name 'UsedSpaceGB' -Default 0)
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
Assert-FreeSpace -Path $vmDir -RequiredGB $usedGB -ReserveGB $MinFreeSpaceGB -Purpose "export of VM $VMName"

New-Item -ItemType Directory -Path $partialDir -Force | Out-Null

$snapshot = $null
$clone    = $null
$mode     = 'direct'
$exported = $false
try {
    if ("$($vm.PowerState)" -eq 'PoweredOff') {
        Export-VApp -VM $vm -Destination $partialDir -Format Ovf -Force | Out-Null
    }
    else {
        $mode = 'linked-clone'
        $snapshot = New-Snapshot -VM $vm -Name "backup_$timestamp" -Description 'Temporary snapshot for backup export' -Quiesce:$Quiesce -Memory:$false
        $datastore = Get-Datastore -RelatedObject $vm | Select-Object -First 1
        $clone = New-VM -Name "$VMName-backup-$timestamp" -VM $vm -LinkedClone -ReferenceSnapshot $snapshot `
                        -VMHost $vm.VMHost -Datastore $datastore
        Export-VApp -VM $clone -Destination $partialDir -Format Ovf -Force | Out-Null
    }

    if (@(Get-ChildItem -LiteralPath $partialDir -Filter '*.ovf' -File -Recurse).Count -eq 0) {
        throw "Export of $VMName finished but produced no .ovf file"
    }
    $exported = $true
}
finally {
    # Clone and snapshot are removed right after the export - before the (possibly long)
    # encryption - so the snapshot does not keep growing on the production VM.
    # Each cleanup step runs even if the previous one fails; the first cleanup error is
    # re-thrown when the export itself succeeded; otherwise it is reported as a warning
    # and the export error wins.
    $cleanupError = $null
    if ($clone) {
        try { Remove-VM -VM $clone -DeletePermanently -Confirm:$false | Out-Null }
        catch { $cleanupError = "Could not remove temporary clone '$($clone.Name)': $($_.Exception.Message)" }
    }
    if ($snapshot) {
        try { Remove-Snapshot -Snapshot $snapshot -Confirm:$false | Out-Null }
        catch { if (-not $cleanupError) { $cleanupError = "Could not remove snapshot '$($snapshot.Name)' on ${VMName}: $($_.Exception.Message)" } }
    }
    if (-not $exported) {
        Remove-Item -LiteralPath $partialDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($cleanupError) { Write-Warning $cleanupError }
    }
}

# Only reached after a successful export.
try {
    Complete-BackupDirectory -Path $partialDir -EncryptionCredential $EncryptionCredential `
        -Iterations $EncryptionIterations -ReserveGB $MinFreeSpaceGB
    Move-Item -LiteralPath $partialDir -Destination $finalDir
}
catch {
    Remove-Item -LiteralPath $partialDir -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
if ($cleanupError) { throw $cleanupError }

$size = (Get-ChildItem -LiteralPath $finalDir -File -Recurse | Measure-Object -Property Length -Sum).Sum
[pscustomobject]@{
    Path      = $finalDir
    SizeMB    = [math]::Round($size / 1MB, 2)
    Mode      = $mode
    Encrypted = $null -ne $EncryptionCredential
}
