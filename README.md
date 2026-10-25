# Windows Backup Automation (FireBird, Oracle, VMware)

[![CI](https://github.com/yvursol/Backup-FireBird-und-Oracle/actions/workflows/ci.yml/badge.svg)](https://github.com/yvursol/Backup-FireBird-und-Oracle/actions/workflows/ci.yml)
![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

PowerShell scripts for nightly backups of FireBird and Oracle databases and VMware
virtual machines on Windows Server - with test restores, encryption, checksums, an
offsite copy, safe retention, an independent freshness check and alerting.

It grew out of day-to-day work with court case-management systems running on FireBird
and VMware. The rules it follows:

- **A backup only counts if it can be restored.** Every FireBird backup is test-restored,
  every Oracle dump is read back by Data Pump before it is accepted.
- **A backup on the same server is not a backup.** New backups are copied to a second
  location (NAS / SMB share) and verified there.
- **Corruption must be noticed before the restore.** Every backup gets a SHA256 manifest;
  the morning check re-hashes the newest copy.
- **Fail loudly.** A failed target gives a non-zero exit code, a Telegram message and an
  event log entry - never a green scheduled task with a missing backup.
- **Retention must not destroy the last good copy.** Old backups are only deleted after a
  successful run, and the newest `MinKeep` copies are always kept.
- **No secrets in files, configs or command lines** - and backup files are encrypted, so a
  copied backup does not leak the court database.

## What it does

| Component | How | Verification |
| --- | --- | --- |
| FireBird | Online `gbak -b` per database (service keeps running) | `gbak -c` test restore into a scratch file |
| Oracle | Data Pump `expdp` (full or selected schemas) | expdp exit code + `impdp SQLFILE=` reads the dump back |
| VMware | OVF export via PowerCLI; running VMs through a temporary snapshot + linked clone | `.ovf` present and non-empty |
| All | Optional AES-256 encryption, SHA256 manifest per backup, offsite copy | manifest re-checked on the offsite store and every morning |

```
02:00  Backup-Run (backup.ps1)
        ├─ config validation, free-space check, load encryption passphrase
        ├─ per VM:       space check (VM size) → snapshot → linked clone → Export-VApp
        │                → remove clone + snapshot → encrypt → SHA256SUMS → final name
        ├─ per FireBird: space check → gbak backup → space check → test restore
        │                → encrypt → manifest → final name
        ├─ Oracle:       space check → expdp → impdp SQLFILE check → encrypt → manifest
        ├─ per target:   local retention → offsite copy (verified there) → offsite retention
        └─ summary       → log, event log, Telegram on failure, exit code

08:00  Backup-Check (check-backup.ps1)
        ├─ newest copy of every target younger than MaxBackupAgeHours, not empty,
        │  and matching its SHA256 manifest?
        └─ same for the offsite store
```

Each target is handled on its own: one broken database does not stop the VM exports.
Backups are written under a temporary name (leading `.`) and renamed only when complete,
so an interrupted run never leaves something that looks like a valid backup.

## Requirements

- Windows Server 2016 or newer, Windows PowerShell 5.1 or PowerShell 7
- FireBird: `gbak.exe` (2.5, 3.0, 4.0, 5.0)
- Oracle: Oracle client with `expdp` and `impdp`; the folder behind the DIRECTORY object
  must be reachable from the backup host (local path or share)
- VMware: [PowerCLI](https://developer.broadcom.com/powercli) and vCenter (linked clones are a vCenter feature)
- Offsite copy: an SMB share (NAS, file server) on **different hardware**, ideally in
  another room or building

## Quick start

```powershell
git clone https://github.com/yvursol/Backup-FireBird-und-Oracle.git C:\BackupAutomation
cd C:\BackupAutomation

# 1. Configuration (config.json is git-ignored)
Copy-Item config.example.json config.json
notepad config.json

# 2. Scheduled tasks + event log source (validates config.json first)
.\setup.ps1                      # or: .\setup.ps1 -Shell pwsh.exe   (PowerShell 7)

# 3. Credentials - must be stored as the account the task runs under (SYSTEM)
psexec -s -i powershell.exe -ExecutionPolicy Bypass -File C:\BackupAutomation\Set-BackupCredentials.ps1

# 4. First run
Start-ScheduledTask -TaskPath '\Backup\' -TaskName 'Backup-Run'
```

`Set-BackupCredentials.ps1` only asks for credentials of the components enabled in
`config.json`.

> **Encryption passphrase:** write it down and keep it outside the backup server
> (password manager, sealed envelope in the safe). The copy stored by
> `Set-BackupCredentials.ps1` is DPAPI-bound to this machine and dies with it. Without the
> passphrase the encrypted backups cannot be restored - by anyone. If you change it later
> with `-Overwrite`, older backups still need the old passphrase.

## Configuration

See [`config.example.json`](config.example.json). Sections for components you do not
use can be removed or set to `"Enabled": false`. The config is validated on every run and
all problems are reported at once.

| Key | Meaning |
| --- | --- |
| `LogPath`, `LogRetentionDays` | Log folder (default `.\logs`) and how long logs are kept |
| `CredentialStorePath` | Folder with the encrypted credentials (default `.\secrets`) |
| `MinFreeSpaceGB` | Free space that must remain on a backup volume. Checked at the start **and before every step that writes data** (backup, test restore, VM export, encryption) with an estimate of what that step needs |
| `Retention.Days` | Delete backups older than this (0 = keep everything) |
| `Retention.MinKeep` | Always keep at least this many newest backups per target |
| `Monitoring.MaxBackupAgeHours` | Age limit for `check-backup.ps1` (26 h leaves slack for a daily job) |
| `Monitoring.VerifyChecksums` | Re-hash the newest local backup every morning (default `true`; reads the whole backup) |
| `Monitoring.VerifyOffsiteChecksums` | Same for the offsite copy (default `false`; it was verified on arrival) |
| `Encryption.Enabled` | Encrypt every backup file (AES-256, see [Security model](#security-model)) |
| `Encryption.CredentialName` | Stored credential whose password is the passphrase |
| `Encryption.Iterations` | PBKDF2 iterations (default 600000, minimum 100000) |
| `Offsite.Path` | Offsite folder, e.g. `\\nas01\backup$\court-srv01`. Layout below it: `VMware\<VM>\`, `FireBird\`, `Oracle\` |
| `Offsite.CredentialName` | Optional. Empty = the task account (SYSTEM = computer account `DOMAIN\HOST$`) needs write access on the share |
| `Offsite.Retention.Days` / `.MinKeep` | Retention on the offsite store (defaults to `Retention`) |
| `Offsite.MinFreeSpaceGB` | Free space that must remain on the offsite store |
| `Offsite.Check` | Let `check-backup.ps1` check the offsite store too (default `true`) |
| `VMware.Quiesce` | Quiesced snapshot through VMware Tools (default `true`) |
| `VMware.IgnoreInvalidCertificate` | Accept self-signed vCenter certificates for this session |
| `VMware.VirtualMachines` | VM names; each must match exactly one VM in vCenter (duplicates in other datacenters are refused) |
| `FireBird.GbakPath` | Full path to `gbak.exe` (differs between FireBird versions) |
| `FireBird.VerifyRestore` | Test restore after each backup (default `true`, needs ~2x backup size free) |
| `FireBird.Databases[].Name` | Used in file names: `<Name>_yyyyMMdd_HHmmss.fbk` |
| `Oracle.DumpDirectoryPath` | The folder of `DirectoryObject` as seen from this machine |
| `Oracle.Schemas` | Empty = `full=y`, otherwise `schemas=A,B` |
| `Oracle.Compression` | `METADATA_ONLY` (default) or `NONE`; `ALL`/`DATA_ONLY` need the Advanced Compression licence |
| `Oracle.VerifyDump`, `Oracle.ImpdpPath` | Read the dump back with `impdp SQLFILE=` (default `true`, `impdp`) |
| `Oracle.UseWallet` | Connect with `/@TNS` via Oracle wallet - no password stored at all |
| `Telegram.NotifyOnSuccess` | Also send a message when everything succeeded |

### Backup files

```
FireBird   <Name>_<yyyyMMdd_HHmmss>.fbk[.enc]   + <Name>_<ts>.sha256
Oracle     <Label>_<ts>.dmp[.enc]  <Label>_<ts>.log   + <Label>_<ts>.sha256
VMware     <VM>\<ts>\...\*.ovf[.enc] *.vmdk[.enc]     + <VM>\<ts>\SHA256SUMS
```

The manifests use the `sha256sum` format, so they can also be checked on Linux
(`cd <folder> && sha256sum -c SHA256SUMS`).

## Offsite copy

After a target was backed up successfully, `backup.ps1` copies every local backup set
that the offsite store does not have yet (so the nights missed during a NAS outage are
caught up), into a temporary folder on the store. The SHA256 manifest is verified **on the
store**, and only then the set gets its final name. A copy that does not match is deleted
and reported. Retention on the store runs afterwards with its own limits, e.g. 14 days
locally and 30 days on the NAS.

An offsite failure fails the run (exit code 1, Telegram), but never touches the local
backups.

Ransomware note: a share that SYSTEM on the backup server can write to can also be
encrypted by malware running as SYSTEM there. Turn on snapshots on the NAS
(Synology/QNAP/TrueNAS "immutable" or read-only snapshots) or use a share whose old
files the backup account cannot modify.

## Exit codes and monitoring

| Script | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `backup.ps1` | all targets OK | at least one target or offsite copy failed | aborted (config, disk space, missing passphrase, unexpected error) |
| `check-backup.ps1` | all backups fresh and intact | stale / missing / empty / corrupted backup, offsite store unreachable | config error |

Summary events are written to the Application log, source `BackupAutomation`:
`1000` OK, `1001` targets failed, `1002` run aborted, `1003` freshness check failed.
This works with both Windows PowerShell 5.1 and PowerShell 7 (the scripts use the .NET
EventLog API; `Write-EventLog` does not exist in PowerShell 7). Messages longer than the
Telegram limit (4096 characters) or the event log limit are shortened with a note; the
full text is always in the log file.

Zabbix example:

```
# zabbix_agentd.conf
UserParameter=backup.check,powershell -NoProfile -ExecutionPolicy Bypass -File "C:\BackupAutomation\check-backup.ps1" -AsJson -NoAlert
```

Use a dependent item with JSONPath `$.status` (`ok` / `fail`) and `$.problems`, or watch
the event log directly with `eventlog[Application,,,BackupAutomation,"1001|1002|1003"]`.
With `VerifyChecksums` the check reads the whole newest backup; raise the Zabbix agent
`Timeout` accordingly or run the check as the scheduled task only.

## Security model

- Credentials are `PSCredential` objects saved with `Export-Clixml`, i.e. encrypted with
  **DPAPI** for the account and machine that created them. A copied file is useless
  elsewhere. The store folder is additionally restricted to that account.
- **Backup encryption** (`Encryption.Enabled`): every backup file is encrypted with
  AES-256-CBC and authenticated with HMAC-SHA256 (encrypt-then-MAC). The keys are derived
  from the passphrase with PBKDF2-HMAC-SHA256 (600000 iterations, random salt per file).
  A wrong passphrase is reported immediately; a modified or damaged file is detected
  during decryption and no plaintext is written. The file format is documented in
  [`lib/BackupNative.cs`](lib/BackupNative.cs); [`tools/decrypt-backup.py`](tools/decrypt-backup.py)
  decrypts without PowerShell. Plaintext only exists under a temporary name until the
  encrypted file is complete. The Oracle `.log` stays readable (no data, only object names).
- FireBird: user and password go to `gbak` through `ISC_USER` / `ISC_PASSWORD` and are
  removed right after - they never appear in the process command line (which every local
  user can read via `Win32_Process`).
- Oracle: the connect string is written into a temporary parameter file that only the
  current account can read; it is deleted after `expdp`/`impdp` exits. With `UseWallet`
  there is no password anywhere.
- The Telegram bot token is stored like any other credential (password field).

## Restore

Step-by-step restore procedures for all three components, including decryption:
[docs/RESTORE.md](docs/RESTORE.md). Test them before you need them.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -SkipPublisherCheck
Install-Module PSScriptAnalyzer
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The tests run without FireBird, Oracle or vCenter: `tests/fakes` contains stand-ins for
`gbak`, `expdp` and `impdp`, and the PowerCLI cmdlets are replaced by stubs. They cover
retention, encryption (incl. the RFC 7914 PBKDF2 test vector and tampering), manifests,
offsite copies, the freshness check, config validation, the failure paths of every backup
script and full runs of `backup.ps1` / `check-backup.ps1`. CI runs them on Windows
PowerShell 5.1 and PowerShell 7.

```
backup.ps1               orchestration, retention, offsite copy, summary, exit code
firebird-backup.ps1      one FireBird database
oracle-backup.ps1        one Data Pump export
vmware-backup.ps1        one VM
check-backup.ps1         freshness + checksum check (separate scheduled task)
decrypt-backup.ps1       verify / decrypt a backup for a restore
setup.ps1                scheduled tasks + event log source
Set-BackupCredentials.ps1
lib/BackupCommon.psm1    config, logging, credentials, encryption, manifests,
                         retention, offsite, alerts
lib/BackupNative.cs      AES/HMAC/PBKDF2 and free space on UNC paths (compiled at load)
tools/decrypt-backup.py  emergency decryption without PowerShell
tests/                   Pester tests
docs/RESTORE.md
```

## Limitations

- VM backups are full OVF exports - fine for a handful of VMs, but not incremental.
  For large environments use a product built on VADP/CBT (Veeam, Nakivo, ...).
- The OVF export of a quiesced snapshot is crash-/filesystem-consistent; databases inside
  VMs should still be backed up with their own tools (that is what the database part is for).
- Oracle Data Pump is a logical export. It does not replace RMAN for point-in-time recovery.
  The `impdp SQLFILE=` check reads the dump header, master table and all metadata, but not
  the table data blocks; their integrity from the moment of the export is covered by SHA256.
- Encryption and hashing read every backup file again. Plan the backup window with
  roughly the time of one extra sequential read (and write, with encryption) of the backup.
- The offsite copy goes to a file share. For S3 or other object storage, sync the offsite
  folder with a tool such as `rclone` as a separate task.

## License

MIT - see [LICENSE](LICENSE).
