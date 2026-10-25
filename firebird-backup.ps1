#Requires -Version 5.1
<#
.SYNOPSIS
    Online backup of one FireBird database with gbak, followed by a test restore.

.DESCRIPTION
    gbak takes a transactionally consistent backup while the server keeps running,
    so the FireBird service must NOT be stopped.

    The backup is written under a temporary name (leading '.'). Only after gbak and the
    test restore both succeeded it is (optionally) encrypted, a SHA256 manifest
    <Name>_<yyyyMMdd_HHmmss>.sha256 is written and the files get their final names:
        <Name>_<timestamp>.fbk[.enc]
        <Name>_<timestamp>.sha256
    A failed run therefore never leaves a file that retention would count as a good copy.

    Free space is checked before each step that writes data (backup, test restore,
    encryption), so a disk that fills up during the night fails this target with a
    clear message instead of breaking in the middle of gbak.

    gbak's verbose output goes to <LogDirectory>/gbak_<Name>_<timestamp>.log.

    Credentials are passed through ISC_USER / ISC_PASSWORD so they do not show up
    in the process command line.

.OUTPUTS
    PSCustomObject with File, SizeMB, Verified, Encrypted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$DatabasePath,
    [Parameter(Mandatory)][string]$BackupPath,
    [Parameter(Mandatory)][string]$GbakPath,
    [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
    [bool]$VerifyRestore = $true,
    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs'),
    # Passphrase for backup encryption; no encryption when omitted.
    [System.Management.Automation.PSCredential]$EncryptionCredential,
    [int]$EncryptionIterations = 600000,
    # Free space that must remain on the backup volume after each step.
    [double]$MinFreeSpaceGB = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1')

if (-not (Test-Path -LiteralPath $GbakPath -PathType Leaf)) {
    throw "gbak not found at '$GbakPath' (FireBird.GbakPath in config.json)"
}
foreach ($dir in $BackupPath, $LogDirectory) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$baseName    = "${Name}_$timestamp"
$partialFile = Join-Path $BackupPath ".$baseName.fbk"
$gbakLog     = Join-Path $LogDirectory "gbak_$baseName.log"
$verifyFile  = Join-Path $BackupPath ".$baseName.verify.fdb"

# The .fbk is normally smaller than the database. If the database file is not visible
# from here (remote server:path syntax), only the reserve can be checked.
$databaseGB = 0
try {
    if (Test-Path -LiteralPath $DatabasePath -PathType Leaf) { $databaseGB = (Get-Item -LiteralPath $DatabasePath).Length / 1GB }
}
catch {
    Write-Verbose "Size of $DatabasePath unknown: $($_.Exception.Message)"
}
Assert-FreeSpace -Path $BackupPath -RequiredGB $databaseGB -ReserveGB $MinFreeSpaceGB -Purpose "FireBird backup of $Name"

$env:ISC_USER     = $Credential.UserName
$env:ISC_PASSWORD = $Credential.GetNetworkCredential().Password

try {
    # -g: skip garbage collection during backup (faster, the restore rebuilds anyway)
    $backup = Invoke-NativeCommand -FilePath $GbakPath -ArgumentList @('-b', '-g', '-v', $DatabasePath, $partialFile)
    Set-Content -LiteralPath $gbakLog -Value $backup.Output -Encoding UTF8

    if ($backup.ExitCode -ne 0) {
        throw "gbak backup of '$DatabasePath' failed with exit code $($backup.ExitCode), see $gbakLog"
    }
    if (-not (Test-Path -LiteralPath $partialFile) -or (Get-Item -LiteralPath $partialFile -Force).Length -eq 0) {
        throw "gbak reported success but the backup file is missing or empty: $partialFile"
    }

    if ($VerifyRestore) {
        # The restored database is usually larger than the .fbk (indexes are rebuilt).
        $restoreGB = 2 * (Get-Item -LiteralPath $partialFile -Force).Length / 1GB
        Assert-FreeSpace -Path $BackupPath -RequiredGB $restoreGB -ReserveGB $MinFreeSpaceGB -Purpose "test restore of $Name"

        $restore = Invoke-NativeCommand -FilePath $GbakPath -ArgumentList @('-c', '-v', $partialFile, $verifyFile)
        Add-Content -LiteralPath $gbakLog -Value (@('', '--- test restore ---') + $restore.Output) -Encoding UTF8
        if ($restore.ExitCode -ne 0) {
            throw "Test restore of $partialFile failed with exit code $($restore.ExitCode), see $gbakLog"
        }
        Remove-Item -LiteralPath $verifyFile -Force -ErrorAction SilentlyContinue
    }

    $set = Complete-BackupFileSet -Directory $BackupPath -BaseName $baseName -ReserveGB $MinFreeSpaceGB `
        -EncryptionCredential $EncryptionCredential -Iterations $EncryptionIterations `
        -File @([pscustomobject]@{ Source = $partialFile; Name = "$baseName.fbk"; Encrypt = $true })
    $finalFile = $set.Files[0]

    [pscustomobject]@{
        File      = $finalFile
        SizeMB    = [math]::Round((Get-Item -LiteralPath $finalFile).Length / 1MB, 2)
        Verified  = $VerifyRestore
        Encrypted = $null -ne $EncryptionCredential
    }
}
finally {
    Remove-Item Env:ISC_USER, Env:ISC_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $verifyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue
}
