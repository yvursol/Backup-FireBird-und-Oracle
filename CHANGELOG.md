# Changelog

## 2.1.0

Config: new optional sections `Encryption` and `Offsite`, new keys
`Monitoring.VerifyChecksums`, `Monitoring.VerifyOffsiteChecksums`, `Oracle.VerifyDump`,
`Oracle.ImpdpPath`. Existing 2.0 configs keep working unchanged (both features are off
until enabled). Oracle users need `DATAPUMP_IMP_FULL_DATABASE` for the new dump check, or
set `Oracle.VerifyDump` to `false`. Backups made before the upgrade have no manifest; the
first `check-backup.ps1` after the upgrade passes once a 2.1 backup run has finished.

### Added
- **Offsite copy** to an SMB share/NAS: every new backup set is copied, verified against
  its SHA256 manifest on the destination and only then given its final name; sets missed
  during an outage are caught up; separate offsite retention; `check-backup.ps1` checks
  the offsite store too.
- **Encryption** of all backup files: AES-256-CBC + HMAC-SHA256, PBKDF2-SHA256 key
  derivation, passphrase stored DPAPI-protected and asked for twice. `decrypt-backup.ps1`
  verifies/decrypts single files, file sets and VM folders; `tools/decrypt-backup.py`
  decrypts without PowerShell.
- **SHA256 manifests** for every backup set (`sha256sum` compatible).
  `check-backup.ps1` re-hashes the newest set every morning (`Monitoring.VerifyChecksums`).
- **Oracle dump check** with `impdp SQLFILE=` after every export.
- `setup.ps1 -Shell pwsh.exe` to run the tasks with PowerShell 7.

### Fixed
- Event log entries were silently skipped under PowerShell 7 (`Write-EventLog` does not
  exist there). The .NET EventLog API is used now, in `setup.ps1` as well.
- Free space was only checked once at the start. It is now checked before every step that
  writes data, with an estimate for that step (database size, 2x for the test restore, VM
  used space, file size for encryption).
- Free space on a UNC `BackupPath` could not be determined (`DriveInfo` does not accept UNC
  paths); `GetDiskFreeSpaceEx` is used now.
- A VM name that exists in several datacenters made `vmware-backup.ps1` work on an array of
  VMs. The name must now match exactly one VM, otherwise the target fails with a clear message.
- Long failure messages could exceed the Telegram limit (4096 characters) and were then
  not delivered at all. Alerts are shortened with a note; the log keeps the full text.
- Module functions did not inherit `$ErrorActionPreference = 'Stop'` from the scripts, so
  some file errors inside the module were non-terminating. The module now sets it itself.

## 2.0.0

Breaking: the config layout changed (`DatabaseBackup.FireBird` → `FireBird`,
`DatabaseBackup.Oracle` → `Oracle`, `TelegramAlerts` → `Telegram`, new `Retention`
and `Monitoring` sections). Start from `config.example.json`. `config.json` is no longer
tracked in git.

### Fixed
- VMware: running VMs are exported through a temporary linked clone. `Export-VApp`
  refuses powered-on VMs, so the snapshot alone never worked.
- Retention deleted backups by age even when the current run failed - after enough
  failed nights nothing was left. It now runs only after a successful backup of that
  target and always keeps the newest `Retention.MinKeep` copies.
- `backup.ps1` returned 0 even when every target failed. Exit code is now 0 / 1 / 2.
- `check-backup.ps1` picked the newest VM folder by `LastWriteTime`, which changes when
  retention deletes files inside an old folder; it now uses the timestamp in the name.
- FireBird: backup files carry the database name, so several databases in one folder
  are checked and pruned independently. `gbak` path is configurable (FireBird 3+ has
  no `bin` folder).
- Oracle: password no longer piped to `expdp` via stdin (unreliable on Windows); dumps
  are moved to `BackupPath` so retention and the check cover them; `COMPRESSION=ALL`
  (licensed option) is no longer the default; exit code 5 is treated as failure.
- Telegram alerts on Server 2016 failed because PowerShell 5.1 defaulted to TLS 1.0.

### Added
- Temporary names during backup; failed runs leave nothing that counts as a backup.
- Config validation with all problems listed at once.
- `check-backup.ps1`: Oracle check, empty-file check, `-AsJson` for Zabbix, Telegram alert,
  separate scheduled task.
- Windows event log summary events (source `BackupAutomation`).
- Shared module `lib/BackupCommon.psm1`.
- Pester tests and GitHub Actions (PSScriptAnalyzer, tests on PowerShell 5.1 and 7).
- `docs/RESTORE.md`.

## 1.0.0

Initial version: VMware OVF export, FireBird `gbak`, Oracle `expdp`, DPAPI credentials,
Telegram alerts, scheduled task.
