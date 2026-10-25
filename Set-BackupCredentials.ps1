#Requires -Version 5.1
<#
.SYNOPSIS
    Interactively stores the credentials referenced in config.json (DPAPI-encrypted).

.DESCRIPTION
    DPAPI binds the encrypted file to the account and machine that created it, so this
    must run as the same account as the scheduled task - SYSTEM by default:

        psexec -s -i powershell.exe -ExecutionPolicy Bypass -File .\Set-BackupCredentials.ps1

    Only credentials used by enabled components are asked for. For Telegram the user
    name is ignored; enter the bot token as the password.

    Encryption passphrase: the user name is ignored, the password is the passphrase. It is
    asked for twice. The stored copy only works on this machine for this account - if the
    server is lost, so is that copy. Write the passphrase down and keep it OUTSIDE this
    server (password manager, sealed envelope in a safe). Without it the encrypted backups
    cannot be restored by anyone.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    # Ask again for credentials that are already stored.
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/BackupCommon.psm1') -Force

$config    = Get-BackupConfig -Path $ConfigPath
$credStore = Get-ConfigValue -Object $config -Name 'CredentialStorePath' -Default (Join-Path $PSScriptRoot 'secrets')

$needed = [ordered]@{}
if (Test-ComponentEnabled -Config $config -Name 'VMware') {
    $needed[$config.VMware.CredentialName] = "vCenter user for $($config.VMware.VCenter)"
}
if (Test-ComponentEnabled -Config $config -Name 'FireBird') {
    foreach ($db in $config.FireBird.Databases) {
        $needed[$db.CredentialName] = "FireBird user for $($db.Name) (backup needs SYSDBA or the database owner)"
    }
}
if ((Test-ComponentEnabled -Config $config -Name 'Oracle') -and -not (Get-ConfigValue -Object $config.Oracle -Name 'UseWallet' -Default $false)) {
    $needed[$config.Oracle.CredentialName] = "Oracle user for $($config.Oracle.TnsName) (full export needs DATAPUMP_EXP_FULL_DATABASE, the dump check DATAPUMP_IMP_FULL_DATABASE)"
}
if ((Test-ComponentEnabled -Config $config -Name 'Offsite') -and (Get-ConfigValue -Object $config.Offsite -Name 'CredentialName')) {
    $needed[$config.Offsite.CredentialName] = "Account with write access to $($config.Offsite.Path) (DOMAIN\user)"
}
$encryptionName = $null
if (Test-ComponentEnabled -Config $config -Name 'Encryption') {
    $encryptionName = $config.Encryption.CredentialName
    $needed[$encryptionName] = 'Backup encryption: any user name, the PASSPHRASE as password (min. 16 characters)'
}
if (Test-ComponentEnabled -Config $config -Name 'Telegram') {
    $needed[$config.Telegram.CredentialName] = 'Telegram bot: any user name, bot token as password'
}

Write-Output "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Output "Store:      $credStore"

foreach ($name in $needed.Keys) {
    $existing = Join-Path $credStore "$name.cred.xml"
    if ((Test-Path -LiteralPath $existing) -and -not $Overwrite) {
        Write-Output "[$name] already stored, skipping (use -Overwrite to replace)"
        continue
    }
    $cred = Get-Credential -Message "[$name] $($needed[$name])"
    if (-not $cred) { Write-Warning "[$name] skipped"; continue }
    if ($name -eq $encryptionName) {
        # A typo here would make every future backup unrecoverable - ask twice.
        $passphrase = $cred.GetNetworkCredential().Password
        if ($passphrase.Length -lt 16) { Write-Warning "[$name] the passphrase must have at least 16 characters - not stored"; continue }
        $again = Get-Credential -UserName $cred.UserName -Message "[$name] enter the passphrase again"
        if (-not $again -or $again.GetNetworkCredential().Password -cne $passphrase) {
            Write-Warning "[$name] the passphrases do not match - not stored"
            continue
        }
        Write-Warning 'Keep a copy of this passphrase OUTSIDE this server. Without it the encrypted backups cannot be restored.'
    }
    $path = Set-BackupCredential -Name $name -Credential $cred -StorePath $credStore
    Write-Output "[$name] stored: $path"
}
