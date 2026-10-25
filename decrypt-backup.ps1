#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies and decrypts an encrypted backup (a single .enc file or a whole backup set).

.DESCRIPTION
    Works on any Windows machine with PowerShell 5.1 or 7 - the original backup server is
    not needed, only the passphrase. Before decrypting, the SHA256 manifest of the set is
    checked when there is one (skip with -SkipChecksum). Every file is authenticated
    (HMAC) while it is decrypted; a wrong passphrase or a modified file is reported and
    no plaintext is left behind.

    -Path can be:
      - one encrypted file              D:\Backup\FireBird\main_db_20261025_020001.fbk.enc
      - the manifest of a file set       D:\Backup\FireBird\main_db_20261025_020001.sha256
      - a VM export folder               D:\Backup\VM\app01\20261025_020001

    Without -Destination the files are only verified (decrypted in memory, nothing written).

    The passphrase is asked for interactively. On the backup server itself, -ConfigPath
    uses the stored passphrase instead (only works as the account that stored it).

.EXAMPLE
    .\decrypt-backup.ps1 -Path D:\Backup\FireBird\main_db_20261025_020001.fbk.enc -Destination C:\Restore

.EXAMPLE
    .\decrypt-backup.ps1 -Path \\nas01\backup$\court-srv01\VMware\app01\20261025_020001 -Destination E:\Restore\app01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Destination,
    [string]$ConfigPath,
    [switch]$SkipChecksum
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1') -Force

if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
$item = Get-Item -LiteralPath $Path -Force

# Work out which files belong to the request and which manifest covers them.
$manifest = $null
if ($item.PSIsContainer) {
    $base  = $item.FullName
    $files = @(Get-ChildItem -LiteralPath $base -File -Recurse -Force)
    $candidate = Join-Path $base 'SHA256SUMS'
    if (Test-Path -LiteralPath $candidate) { $manifest = $candidate }
}
elseif ($item.Name -like '*.sha256') {
    $base     = $item.DirectoryName
    $manifest = $item.FullName
    $stem     = [IO.Path]::GetFileNameWithoutExtension($item.Name)
    $files    = @(Get-ChildItem -LiteralPath $base -File -Force | Where-Object { $_.Name -like "$stem.*" })
}
else {
    $base  = $item.DirectoryName
    $files = @($item)
    if ($item.Name -match '^(.+_\d{8}_\d{6})\.') {
        $candidate = Join-Path $base "$($Matches[1]).sha256"
        if (Test-Path -LiteralPath $candidate) { $manifest = $candidate }
    }
}

if ($manifest -and -not $SkipChecksum) {
    $problems = @(Test-BackupManifest -Path $manifest)
    if ($problems.Count -gt 0) {
        throw "Checksum verification failed ($manifest):`n  - $($problems -join "`n  - ")`nUse -SkipChecksum to try anyway."
    }
    Write-Output "SHA256 OK: $manifest"
}
elseif (-not $manifest) {
    Write-Warning 'No SHA256 manifest found - only the per-file HMAC will be checked.'
}

$encrypted = @($files | Where-Object { $_.Name -like '*.enc' })
if ($encrypted.Count -eq 0) { throw "No encrypted (.enc) files in $Path" }

if ($ConfigPath) {
    $config    = Get-BackupConfig -Path $ConfigPath
    $credStore = Get-ConfigValue -Object $config -Name 'CredentialStorePath' -Default (Join-Path $PSScriptRoot 'secrets')
    $cred      = Get-BackupCredential -Name $config.Encryption.CredentialName -StorePath $credStore
}
else {
    $secure = Read-Host -Prompt 'Backup passphrase' -AsSecureString
    $cred   = New-Object System.Management.Automation.PSCredential('backup', $secure)
}

if ($Destination -and -not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

foreach ($f in $encrypted) {
    $relative = $f.FullName.Substring($base.TrimEnd('\', '/').Length).TrimStart('\', '/')
    $started  = Get-Date
    if ($Destination) {
        $target = Join-Path $Destination ($relative -replace '\.enc$', '')
        $targetDir = Split-Path -Path $target -Parent
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Unprotect-BackupFile -Path $f.FullName -Destination $target -Credential $cred
        Write-Output ('Decrypted {0} -> {1} ({2:N0}s)' -f $relative, $target, ((Get-Date) - $started).TotalSeconds)
    }
    else {
        Unprotect-BackupFile -Path $f.FullName -Credential $cred
        Write-Output ('Verified  {0} ({1:N0}s)' -f $relative, ((Get-Date) - $started).TotalSeconds)
    }
}

if ($Destination) {
    # Unencrypted companions (Oracle .log, nothing else by default) are copied as they are.
    foreach ($f in @($files | Where-Object { $_.Name -notlike '*.enc' -and $_.Name -notlike '*.sha256' -and $_.Name -ne 'SHA256SUMS' })) {
        $relative = $f.FullName.Substring($base.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $target = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $f.FullName -Destination $target }
    }
}
