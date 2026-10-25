# Restore procedures

Backups are only worth what a restore proves. Run through these steps on a test
system at least once, and again after FireBird/Oracle/vSphere upgrades.

File names follow the pattern `<Name>_yyyyMMdd_HHmmss.<ext>` (FireBird, Oracle) or
`<VM>\yyyyMMdd_HHmmss\` (VMware). Pick the newest set unless you need an older state.

## Step 0: pick the copy, check it, decrypt it

1. **Which copy?** The local one on the backup server (`D:\Backup\...`) or, if that server
   or its disks are gone, the offsite one (`<Offsite.Path>\FireBird`, `\Oracle`,
   `\VMware\<VM>`). Both have the same file names.
2. **Check it.** Every set has a SHA256 manifest (`<Name>_<ts>.sha256`, or `SHA256SUMS`
   in a VM folder). `decrypt-backup.ps1` checks it automatically; by hand:

   ```powershell
   Import-Module C:\BackupAutomation\lib\BackupCommon.psm1
   Test-BackupManifest -Path D:\Backup\FireBird\main_db_20261025_020001.sha256   # no output = OK
   ```

   On Linux: `cd <folder> && sha256sum -c main_db_20261025_020001.sha256`.
3. **Decrypt** (only if the files end in `.enc`). You need the passphrase - the copy stored
   on the backup server is useless on any other machine. Copy the repository (or just
   `decrypt-backup.ps1` + `lib\`) to any Windows machine:

   ```powershell
   # one database backup
   .\decrypt-backup.ps1 -Path D:\Backup\FireBird\main_db_20261025_020001.fbk.enc -Destination C:\Restore
   # a whole VM export folder (all .enc files, keeps the folder structure)
   .\decrypt-backup.ps1 -Path \\nas01\backup$\court-srv01\VMware\app01\20261025_020001 -Destination E:\Restore\app01
   # only check that it can be decrypted, write nothing
   .\decrypt-backup.ps1 -Path D:\Backup\Oracle\orcl_20261025_020001.sha256
   ```

   The script asks for the passphrase. On the backup server itself, as the task account,
   `-ConfigPath C:\BackupAutomation\config.json` uses the stored one instead. A wrong
   passphrase is reported immediately; a damaged file fails the integrity check and no
   output is left behind.

   Without Windows: `pip install cryptography`, then
   `python3 tools/decrypt-backup.py main_db_20261025_020001.fbk.enc main_db.fbk`.

   Decrypted files need as much free space as the backup itself. Delete them after the
   restore - they are not protected.

The steps below start from the decrypted `.fbk` / `.dmp` / OVF folder.

## FireBird

Every `.fbk` was already test-restored when it was created, so a restore failing
now points to the target environment (version, disk space, permissions), not to the
backup file.

1. Copy the `.fbk` to the database server if needed.
2. Restore into a **new** file - never over the live database:

   ```powershell
   $cred = Get-Credential SYSDBA
   $env:ISC_USER = $cred.UserName; $env:ISC_PASSWORD = $cred.GetNetworkCredential().Password
   & 'C:\Program Files\Firebird\Firebird_3_0\gbak.exe' -c -v `
       'D:\Backup\FireBird\main_db_20261025_020001.fbk' `
       'C:\Data\Firebird\MAIN_restored.FDB'
   Remove-Item Env:ISC_USER, Env:ISC_PASSWORD
   ```

3. Check the restored database:

   ```powershell
   & 'C:\Program Files\Firebird\Firebird_3_0\gfix.exe' -v -full 'C:\Data\Firebird\MAIN_restored.FDB'
   ```

4. Swap it in: stop the applications, stop the FireBird service, rename the old `.FDB`
   (keep it until everything is confirmed), rename the restored file to the original
   name, start the service, check the application.

Restoring into a newer FireBird major version than the one that made the backup is the
normal upgrade path; the other direction does not work.

## Oracle (Data Pump)

The dump lives in `Oracle.BackupPath`. Data Pump reads dumps from a DIRECTORY object,
so copy it back first:

1. Copy `orcl_<timestamp>.dmp` into the folder of `DATA_PUMP_DIR` (or another
   DIRECTORY object) on the database server.
2. Look at the contents without importing anything:

   ```
   impdp system@ORCL directory=DATA_PUMP_DIR dumpfile=orcl_20261025_020001.dmp sqlfile=preview.sql
   ```

3. Import - typically a single schema into a test schema first:

   ```
   impdp system@ORCL directory=DATA_PUMP_DIR dumpfile=orcl_20261025_020001.dmp ^
         logfile=imp_hr.log schemas=HR remap_schema=HR:HR_RESTORE
   ```

   For a full restore into an empty database use `full=y`. `table_exists_action`
   (`skip`, `replace`, `truncate`, `append`) controls what happens with existing tables.
4. Check `imp_hr.log` for `ORA-` errors and compare object counts
   (`select object_type, count(*) from dba_objects where owner = 'HR_RESTORE' group by object_type`).

A Data Pump export is a logical snapshot at export time. For point-in-time recovery
you need RMAN backups with archived redo logs.

## VMware

Each backup folder contains an OVF (`.ovf` + `.vmdk` disks, possibly `.mf`).

1. vSphere Client → *Deploy OVF Template* → *Local file* → select all files of the
   export folder. Or with PowerCLI:

   ```powershell
   Connect-VIServer vcenter.example.local
   $ovf = Get-ChildItem 'D:\Backup\VM\app01\20261025_020001' -Filter *.ovf -Recurse | Select-Object -First 1
   Import-VApp -Source $ovf.FullName -Name 'app01-restored' `
       -VMHost (Get-VMHost esx01.example.local) -Datastore (Get-Datastore ds01) -DiskStorageFormat Thin
   ```

2. **Before powering on**, disconnect the network adapters or move them to an isolated
   port group - the restored VM has the same hostname and IP as the original.
   Running VMs were exported through a clone, so the MAC addresses are new; Windows
   may show the NIC as a new device.
3. Power on, check services and data, then either replace the original VM or copy the
   needed files out of it.

## After every restore test

Write down the date, the backup used, the time it took and any surprise. The time is
your real recovery time - the number management will ask for.
