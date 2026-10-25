#Requires -Version 5.1
<#
.SYNOPSIS
    Oracle logical backup with Data Pump (expdp), verified with impdp SQLFILE.

.DESCRIPTION
    expdp writes the dump into an Oracle DIRECTORY object on the database server.
    DumpDirectoryPath is the same folder as seen from this machine (local path if the
    script runs on the DB server, otherwise a UNC share).

    Verification (VerifyDump, default on): impdp runs with SQLFILE= against the new dump.
    That imports nothing - it only writes the DDL to a script - but Data Pump has to open
    the dump, read its master table and parse all metadata. A truncated or unreadable dump
    fails here. Table data blocks are not read by SQLFILE; from this point on their
    integrity is covered by the SHA256 manifest. The generated .sql is deleted, the impdp
    log is kept in LogDirectory.

    After that the .dmp (optionally encrypted) and the expdp .log are moved to BackupPath
    together with a SHA256 manifest:
        <Label>_<timestamp>.dmp[.enc], <Label>_<timestamp>.log, <Label>_<timestamp>.sha256

    All options, including the connect string, go into a parameter file that is
    readable only by the current account and deleted afterwards. Nothing secret ever
    appears on the expdp/impdp command line.

    Data Pump exit codes: 0 = success, 1 = failure, 5 = finished with errors (ORA- messages
    in the log). 5 is treated as a failure: such a dump may be missing objects. The
    files are then left in DumpDirectoryPath for inspection.

.OUTPUTS
    PSCustomObject with File, SizeMB, Verified, Encrypted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$TnsName,
    [Parameter(Mandatory)][string]$DirectoryObject,
    [Parameter(Mandatory)][string]$DumpDirectoryPath,
    [Parameter(Mandatory)][string]$BackupPath,
    [bool]$UseWallet = $false,
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$Schemas = @(),
    # COMPRESSION=ALL / DATA_ONLY require the Advanced Compression Option licence.
    [ValidateSet('ALL', 'DATA_ONLY', 'METADATA_ONLY', 'NONE')][string]$Compression = 'METADATA_ONLY',
    [string]$ExpdpPath = 'expdp',
    [bool]$VerifyDump = $true,
    [string]$ImpdpPath = 'impdp',
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

if (-not (Test-Path -LiteralPath $DumpDirectoryPath)) {
    throw "DumpDirectoryPath '$DumpDirectoryPath' is not reachable. It must point to the folder of DIRECTORY object $DirectoryObject."
}
foreach ($dir in $BackupPath, $LogDirectory) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if ($UseWallet) {
    # Oracle wallet / secure external password store: no password anywhere.
    $userId = "/@$TnsName"
}
else {
    if (-not $Credential) { throw 'A credential is required when UseWallet is false.' }
    $password = $Credential.GetNetworkCredential().Password
    if ($password.Contains('"')) { throw 'The Oracle password must not contain a double quote character.' }
    $userId = '{0}/"{1}"@{2}' -f $Credential.UserName, $password, $TnsName
}

function Invoke-DataPump {
    # Runs expdp/impdp with a parameter file that only the current account can read.
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string[]]$Parameter)
    $parFile = Join-Path ([IO.Path]::GetTempPath()) ("datapump_{0}.par" -f [guid]::NewGuid().ToString('N'))
    try {
        # Create the file empty, lock down the ACL, only then write the connect string.
        New-Item -ItemType File -Path $parFile -Force | Out-Null
        Protect-File -Path $parFile
        Set-Content -LiteralPath $parFile -Encoding ASCII -Value (@("userid=$userId") + $Parameter)
        Invoke-NativeCommand -FilePath $Executable -ArgumentList @("parfile=$parFile")
    }
    finally {
        Remove-Item -LiteralPath $parFile -Force -ErrorAction SilentlyContinue
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$baseName  = "${Label}_$timestamp"
$dumpName  = "$baseName.dmp"
$logName   = "$baseName.log"
$scope     = if ($Schemas.Count -gt 0) { 'schemas=' + ($Schemas -join ',') } else { 'full=y' }

# The dump size is unknown in advance; at least the reserve must be there.
Assert-FreeSpace -Path $BackupPath -ReserveGB $MinFreeSpaceGB -Purpose "Oracle export $Label"

$result = Invoke-DataPump -Executable $ExpdpPath -Parameter @(
    "directory=$DirectoryObject"
    "dumpfile=$dumpName"
    "logfile=$logName"
    $scope
    "compression=$Compression"
)

$serverDump = Join-Path $DumpDirectoryPath $dumpName
$serverLog  = Join-Path $DumpDirectoryPath $logName

switch ($result.ExitCode) {
    0 { }
    5 { throw "expdp finished with errors (exit code 5). Dump and log left in $DumpDirectoryPath for inspection: $logName" }
    default { throw "expdp failed with exit code $($result.ExitCode). Log: $serverLog" }
}

if (-not (Test-Path -LiteralPath $serverDump) -or (Get-Item -LiteralPath $serverDump).Length -eq 0) {
    throw "expdp reported success but $serverDump is missing or empty"
}

if ($VerifyDump) {
    $sqlName       = "$baseName.verify.sql"
    $verifyLogName = "$baseName.verify.log"
    $verify = Invoke-DataPump -Executable $ImpdpPath -Parameter @(
        "directory=$DirectoryObject"
        "dumpfile=$dumpName"
        "sqlfile=$sqlName"
        "logfile=$verifyLogName"
    )
    Remove-Item -LiteralPath (Join-Path $DumpDirectoryPath $sqlName) -Force -ErrorAction SilentlyContinue
    $verifyLog = Join-Path $DumpDirectoryPath $verifyLogName
    $keptLog   = Join-Path $LogDirectory "impdp_verify_$baseName.log"
    if (Test-Path -LiteralPath $verifyLog) { Move-Item -LiteralPath $verifyLog -Destination $keptLog -Force }
    if ($verify.ExitCode -ne 0) {
        throw "Dump verification (impdp SQLFILE) failed with exit code $($verify.ExitCode). Dump left in $DumpDirectoryPath, log: $keptLog"
    }
}

$files = @([pscustomobject]@{ Source = $serverDump; Name = $dumpName; Encrypt = $true })
if (Test-Path -LiteralPath $serverLog) {
    $files += [pscustomobject]@{ Source = $serverLog; Name = $logName; Encrypt = $false }
}
$set = Complete-BackupFileSet -Directory $BackupPath -BaseName $baseName -File $files -ReserveGB $MinFreeSpaceGB `
    -EncryptionCredential $EncryptionCredential -Iterations $EncryptionIterations
$finalDump = $set.Files[0]

[pscustomobject]@{
    File      = $finalDump
    SizeMB    = [math]::Round((Get-Item -LiteralPath $finalDump).Length / 1MB, 2)
    Verified  = $VerifyDump
    Encrypted = $null -ne $EncryptionCredential
}
