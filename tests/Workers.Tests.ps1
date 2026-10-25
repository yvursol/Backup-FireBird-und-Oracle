BeforeAll {
    $root  = Split-Path $PSScriptRoot -Parent
    $fakes = Join-Path $PSScriptRoot 'fakes'
    Import-Module (Join-Path $root 'lib/BackupCommon.psm1') -Force

    function New-TestCredential([string]$User, [string]$Password) {
        $secure = [System.Net.NetworkCredential]::new('', $Password).SecurePassword
        New-Object System.Management.Automation.PSCredential($User, $secure)
    }
}

Describe 'firebird-backup.ps1' {
    BeforeEach {
        $backupDir = Join-Path $TestDrive ([guid]::NewGuid())
        $logDir    = Join-Path $backupDir 'logs'
        $argsFile  = Join-Path $TestDrive 'gbak-args.txt'
        Remove-Item $argsFile -ErrorAction SilentlyContinue
        $env:FAKE_ARGS_FILE = $argsFile
        $params = @{
            Name         = 'main_db'
            DatabasePath = 'C:\Data\MAIN.FDB'
            BackupPath   = $backupDir
            GbakPath     = Join-Path $fakes 'gbak.ps1'
            Credential   = New-TestCredential 'SYSDBA' 'Secr3t!'
            LogDirectory = $logDir
        }
    }
    AfterEach {
        Remove-Item Env:FAKE_ARGS_FILE, Env:FAKE_GBAK_FAIL, Env:FAKE_GBAK_EMPTY -ErrorAction SilentlyContinue
    }

    It 'creates a verified <Name>_<timestamp>.fbk and cleans up temporary files' {
        $result = & (Join-Path $root 'firebird-backup.ps1') @params

        $result.Verified | Should -BeTrue
        Split-Path $result.File -Leaf | Should -Match '^main_db_\d{8}_\d{6}\.fbk$'
        $base = (Split-Path $result.File -Leaf) -replace '\.fbk$', ''
        @(Get-ChildItem $backupDir -File -Force | Sort-Object Name).Name | Should -Be @("$base.fbk", "$base.sha256")
        Test-BackupManifest -Path (Join-Path $backupDir "$base.sha256") | Should -BeNullOrEmpty
        @(Get-ChildItem $logDir -Filter 'gbak_main_db_*.log').Count | Should -Be 1
    }

    It 'passes the password via environment only and clears it afterwards' {
        & (Join-Path $root 'firebird-backup.ps1') @params | Out-Null

        Get-Content $argsFile -Raw | Should -Not -Match 'Secr3t'
        Get-Content (Get-ChildItem $logDir -Filter '*.log').FullName -Raw | Should -Match 'ISC_USER=SYSDBA'
        $env:ISC_USER | Should -BeNullOrEmpty
        $env:ISC_PASSWORD | Should -BeNullOrEmpty
    }

    It 'runs the test restore unless disabled' {
        & (Join-Path $root 'firebird-backup.ps1') @params | Out-Null
        (Get-Content $argsFile)[1] | Should -Match '^-c '

        Remove-Item $argsFile
        $result = & (Join-Path $root 'firebird-backup.ps1') @params -VerifyRestore $false
        @(Get-Content $argsFile).Count | Should -Be 1
        $result.Verified | Should -BeFalse
    }

    It 'fails and leaves no backup file when gbak fails' {
        $env:FAKE_GBAK_FAIL = '-b'
        { & (Join-Path $root 'firebird-backup.ps1') @params } | Should -Throw '*exit code 1*'
        @(Get-ChildItem $backupDir -File -Force).Count | Should -Be 0
    }

    It 'fails and leaves no backup file when the test restore fails' {
        $env:FAKE_GBAK_FAIL = '-c'
        { & (Join-Path $root 'firebird-backup.ps1') @params } | Should -Throw '*Test restore*'
        @(Get-ChildItem $backupDir -File -Force).Count | Should -Be 0
    }

    It 'fails on an empty backup file even when gbak returns 0' {
        $env:FAKE_GBAK_EMPTY = '1'
        { & (Join-Path $root 'firebird-backup.ps1') @params } | Should -Throw '*missing or empty*'
    }

    It 'encrypts the verified backup and removes every plaintext copy' {
        $enc = New-TestCredential 'x' 'correct horse battery staple'
        $result = & (Join-Path $root 'firebird-backup.ps1') @params -EncryptionCredential $enc -EncryptionIterations 1000

        $result.Encrypted | Should -BeTrue
        $result.Verified | Should -BeTrue
        Split-Path $result.File -Leaf | Should -Match '^main_db_\d{8}_\d{6}\.fbk\.enc$'
        @(Get-ChildItem $backupDir -File -Force | Where-Object { $_.Name -notlike '*.enc' -and $_.Name -notlike '*.sha256' }).Count | Should -Be 0
        [BackupAutomation.FileCrypto]::IsEncryptedFile($result.File) | Should -BeTrue

        $plain = Join-Path $TestDrive "restored_$([guid]::NewGuid()).fbk"
        Unprotect-BackupFile -Path $result.File -Destination $plain -Credential $enc
        Get-Content $plain | Should -Be 'fake -b output'
    }

    It 'stops before gbak when the reserve would not be left free' {
        { & (Join-Path $root 'firebird-backup.ps1') @params -MinFreeSpaceGB 1e9 } | Should -Throw '*Not enough free space for FireBird backup of main_db*'
        Test-Path $argsFile | Should -BeFalse
    }

    It 'fails with a clear message when gbak is not installed' {
        $params.GbakPath = Join-Path $TestDrive 'no-gbak.exe'
        { & (Join-Path $root 'firebird-backup.ps1') @params } | Should -Throw '*GbakPath*'
    }
}

Describe 'oracle-backup.ps1' {
    BeforeEach {
        $dumpDir   = New-Item -ItemType Directory (Join-Path $TestDrive "dpdump_$([guid]::NewGuid())")
        $backupDir = Join-Path $TestDrive "ora_$([guid]::NewGuid())"
        $capture   = Join-Path $TestDrive 'expdp-capture.txt'
        $env:FAKE_DUMP_DIR      = $dumpDir.FullName
        $env:FAKE_EXPDP_CAPTURE = $capture
        $env:FAKE_IMPDP_CAPTURE = Join-Path $TestDrive "impdp-capture_$([guid]::NewGuid()).txt"
        $params = @{
            Label             = 'orcl'
            TnsName           = 'ORCL'
            DirectoryObject   = 'DATA_PUMP_DIR'
            DumpDirectoryPath = $dumpDir.FullName
            BackupPath        = $backupDir
            Credential        = New-TestCredential 'backup_user' 'Or@cle1'
            ExpdpPath         = Join-Path $fakes 'expdp.ps1'
            ImpdpPath         = Join-Path $fakes 'impdp.ps1'
            LogDirectory      = Join-Path $TestDrive "oralogs_$([guid]::NewGuid())"
        }
    }
    AfterEach {
        Remove-Item Env:FAKE_DUMP_DIR, Env:FAKE_EXPDP_CAPTURE, Env:FAKE_EXPDP_EXIT, Env:FAKE_IMPDP_EXIT, Env:FAKE_IMPDP_CAPTURE -ErrorAction SilentlyContinue
    }

    It 'moves dump and log to BackupPath with <Label>_<timestamp> names and a manifest' {
        $result = & (Join-Path $root 'oracle-backup.ps1') @params

        Split-Path $result.File -Leaf | Should -Match '^orcl_\d{8}_\d{6}\.dmp$'
        $result.Verified | Should -BeTrue
        @(Get-ChildItem $backupDir | Sort-Object Extension).Extension | Should -Be @('.dmp', '.log', '.sha256')
        Test-BackupManifest -Path (Get-ChildItem $backupDir -Filter '*.sha256').FullName | Should -BeNullOrEmpty
        @(Get-ChildItem $dumpDir).Count | Should -Be 0
    }

    It 'verifies the dump with impdp SQLFILE and keeps the impdp log' {
        & (Join-Path $root 'oracle-backup.ps1') @params | Out-Null

        $imp = Get-Content $env:FAKE_IMPDP_CAPTURE
        $imp | Should -Contain 'userid=backup_user/"Or@cle1"@ORCL'
        ($imp | Where-Object { $_ -like 'sqlfile=*' }) | Should -Match '^sqlfile=orcl_\d{8}_\d{6}\.verify\.sql$'
        @(Get-ChildItem $params.LogDirectory -Filter 'impdp_verify_orcl_*.log').Count | Should -Be 1
    }

    It 'fails and leaves the dump for inspection when the impdp check fails' {
        $env:FAKE_IMPDP_EXIT = '5'
        { & (Join-Path $root 'oracle-backup.ps1') @params } | Should -Throw '*impdp SQLFILE*exit code 5*'
        @(Get-ChildItem $dumpDir -Filter '*.dmp').Count | Should -Be 1
        @(Get-ChildItem $backupDir).Count | Should -Be 0
    }

    It 'skips the impdp check when VerifyDump is off' {
        $result = & (Join-Path $root 'oracle-backup.ps1') @params -VerifyDump $false
        $result.Verified | Should -BeFalse
        Test-Path $env:FAKE_IMPDP_CAPTURE | Should -BeFalse
    }

    It 'encrypts the dump but not the expdp log' {
        $enc = New-TestCredential 'x' 'correct horse battery staple'
        $result = & (Join-Path $root 'oracle-backup.ps1') @params -EncryptionCredential $enc -EncryptionIterations 1000

        $result.Encrypted | Should -BeTrue
        Split-Path $result.File -Leaf | Should -Match '^orcl_\d{8}_\d{6}\.dmp\.enc$'
        @(Get-ChildItem $backupDir -Filter '*.dmp').Count | Should -Be 0
        @(Get-ChildItem $backupDir -Filter '*.log').Count | Should -Be 1
        @(Get-ChildItem $dumpDir).Count | Should -Be 0
        $plain = Join-Path $TestDrive "plain_$([guid]::NewGuid()).dmp"
        Unprotect-BackupFile -Path $result.File -Destination $plain -Credential $enc
        Get-Content $plain | Should -Be 'fake dump'
    }

    It 'keeps the password out of the command line and deletes the parfile' {
        & (Join-Path $root 'oracle-backup.ps1') @params | Out-Null

        $captured = Get-Content $capture
        ($captured | Where-Object { $_ -like 'ARGS:*' }) | Should -Not -Match 'Or@cle1'
        $captured | Should -Contain 'userid=backup_user/"Or@cle1"@ORCL'
        $parFile = ($captured | Where-Object { $_ -like 'PARFILE:*' }) -replace '^PARFILE: ', ''
        Test-Path $parFile | Should -BeFalse
    }

    It 'uses full=y by default and schemas= when given, with licence-free compression' {
        & (Join-Path $root 'oracle-backup.ps1') @params | Out-Null
        Get-Content $capture | Should -Contain 'full=y'
        Get-Content $capture | Should -Contain 'compression=METADATA_ONLY'

        $params.BackupPath = "$backupDir-2"
        & (Join-Path $root 'oracle-backup.ps1') @params -Schemas 'HR', 'SALES' | Out-Null
        Get-Content $capture | Should -Contain 'schemas=HR,SALES'
    }

    It 'connects through the wallet without any credential' {
        $params.Remove('Credential')
        & (Join-Path $root 'oracle-backup.ps1') @params -UseWallet $true | Out-Null
        Get-Content $capture | Should -Contain 'userid=/@ORCL'
    }

    It 'treats exit code 5 as failure and leaves the files for inspection' {
        $env:FAKE_EXPDP_EXIT = '5'
        { & (Join-Path $root 'oracle-backup.ps1') @params } | Should -Throw '*exit code 5*'
        @(Get-ChildItem $dumpDir).Count | Should -Be 2
        Test-Path $backupDir | Should -BeTrue
        @(Get-ChildItem $backupDir).Count | Should -Be 0
        Test-Path $env:FAKE_IMPDP_CAPTURE | Should -BeFalse
    }

    It 'fails on exit code 1' {
        $env:FAKE_EXPDP_EXIT = '1'
        { & (Join-Path $root 'oracle-backup.ps1') @params } | Should -Throw '*exit code 1*'
    }

    It 'refuses a password containing a double quote' {
        $params.Credential = New-TestCredential 'u' 'a"b'
        { & (Join-Path $root 'oracle-backup.ps1') @params } | Should -Throw '*double quote*'
    }

    It 'fails early when the dump directory is not reachable' {
        $params.DumpDirectoryPath = Join-Path $TestDrive 'no-share'
        { & (Join-Path $root 'oracle-backup.ps1') @params } | Should -Throw '*not reachable*'
    }
}

Describe 'vmware-backup.ps1' {
    BeforeAll {
        # Minimal stand-ins for the PowerCLI cmdlets the script uses.
        $global:VmCalls = New-Object System.Collections.Generic.List[string]
        $global:VmFail  = @{}

        function global:Get-VM {
            param($Name)
            foreach ($h in $global:VmHosts) { [pscustomobject]@{ Name = $Name; PowerState = $global:VmPowerState; VMHost = $h; UsedSpaceGB = $global:VmUsedGB } }
        }
        function global:Get-Datastore { param($RelatedObject) [pscustomobject]@{ Name = 'ds01' } }
        function global:New-Snapshot {
            param($VM, $Name, $Description, [switch]$Quiesce, [switch]$Memory)
            $global:VmCalls.Add("New-Snapshot quiesce=$Quiesce")
            [pscustomobject]@{ Name = $Name }
        }
        function global:New-VM {
            param($Name, $VM, [switch]$LinkedClone, $ReferenceSnapshot, $VMHost, $Datastore)
            $global:VmCalls.Add("New-VM $Name linked=$LinkedClone")
            [pscustomobject]@{ Name = $Name; PowerState = 'PoweredOff' }
        }
        function global:Export-VApp {
            param($VM, $Destination, $Format, [switch]$Force)
            $global:VmCalls.Add("Export-VApp $($VM.Name)")
            if ($global:VmFail['Export']) { throw 'simulated export failure' }
            $dir = New-Item -ItemType Directory -Path (Join-Path $Destination $VM.Name) -Force
            Set-Content (Join-Path $dir "$($VM.Name).ovf") '<Envelope/>'
            Set-Content (Join-Path $dir "$($VM.Name)-disk1.vmdk") 'disk'
        }
        function global:Remove-VM {
            param($VM, [switch]$DeletePermanently, [switch]$Confirm)
            $global:VmCalls.Add("Remove-VM $($VM.Name)")
        }
        function global:Remove-Snapshot {
            param($Snapshot, [switch]$Confirm)
            $global:VmCalls.Add('Remove-Snapshot')
            $global:VmEncryptedAtSnapshotRemoval = @(Get-ChildItem -Path $global:VmBackupDir -Filter '*.enc' -Recurse -Force -ErrorAction SilentlyContinue).Count
            if ($global:VmFail['RemoveSnapshot']) { throw 'snapshot locked' }
        }
    }
    AfterAll {
        'Get-VM', 'Get-Datastore', 'New-Snapshot', 'New-VM', 'Export-VApp', 'Remove-VM', 'Remove-Snapshot' |
            ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
        Remove-Variable VmCalls, VmFail, VmPowerState, VmHosts, VmUsedGB, VmBackupDir, VmEncryptedAtSnapshotRemoval -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:VmCalls.Clear()
        $global:VmFail = @{}
        $global:VmPowerState = 'PoweredOn'
        $global:VmHosts = @('esx01')
        $global:VmUsedGB = 1
        $backupDir = Join-Path $TestDrive "vm_$([guid]::NewGuid())"
        $global:VmBackupDir = $backupDir
    }

    It 'exports a running VM through a linked clone and removes clone and snapshot' {
        $result = & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir

        $result.Mode | Should -Be 'linked-clone'
        $global:VmCalls[0] | Should -Be 'New-Snapshot quiesce=True'
        $global:VmCalls[1] | Should -Match '^New-VM app01-backup-\d{8}_\d{6} linked=True$'
        $global:VmCalls[2] | Should -Match '^Export-VApp app01-backup-'
        $global:VmCalls | Should -Contain 'Remove-Snapshot'
        ($global:VmCalls | Where-Object { $_ -like 'Remove-VM app01-backup-*' }).Count | Should -Be 1
        Split-Path $result.Path -Leaf | Should -Match '^\d{8}_\d{6}$'
        Test-BackupFreshness -Path (Join-Path $backupDir 'app01') -Directory -MaxAgeHours 1 -Label 'app01' -RequiredPattern '*.ovf' -VerifyChecksums |
            Should -BeNullOrEmpty
        $lines = @(Get-Content (Join-Path $result.Path 'SHA256SUMS'))
        $lines.Count | Should -Be 2
        @($lines -match '^[0-9a-f]{64}  app01-backup-\d{8}_\d{6}/app01-backup-\d{8}_\d{6}\.ovf$').Count | Should -Be 1
    }

    It 'refuses an ambiguous VM name instead of exporting one of them' {
        $global:VmHosts = @('esx01', 'esx02')
        { & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir } | Should -Throw '*ambiguous*2 VMs*esx01*esx02*'
        $global:VmCalls.Count | Should -Be 0
    }

    It 'reports a VM that does not exist' {
        $global:VmHosts = @()
        { & (Join-Path $root 'vmware-backup.ps1') -VMName 'ghost' -BackupPath $backupDir } | Should -Throw "*VM 'ghost' not found*"
    }

    It 'checks the space for the VM size before taking a snapshot' {
        $global:VmUsedGB = 1e9
        { & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir } | Should -Throw '*Not enough free space for export of VM app01*'
        $global:VmCalls.Count | Should -Be 0
    }

    It 'encrypts every exported file only after clone and snapshot are gone' {
        $enc = New-TestCredential 'x' 'correct horse battery staple'
        $result = & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir -EncryptionCredential $enc -EncryptionIterations 1000

        $result.Encrypted | Should -BeTrue
        $global:VmEncryptedAtSnapshotRemoval | Should -Be 0
        $files = @(Get-ChildItem $result.Path -File -Recurse | Where-Object Name -ne 'SHA256SUMS')
        $files.Count | Should -Be 2
        @($files | Where-Object { $_.Name -notlike '*.enc' }).Count | Should -Be 0
        Test-BackupFreshness -Path (Join-Path $backupDir 'app01') -Directory -MaxAgeHours 1 -Label 'app01' -RequiredPattern '*.ovf', '*.ovf.enc' -VerifyChecksums |
            Should -BeNullOrEmpty
    }

    It 'exports a powered-off VM directly' {
        $global:VmPowerState = 'PoweredOff'
        $result = & (Join-Path $root 'vmware-backup.ps1') -VMName 'db01' -BackupPath $backupDir

        $result.Mode | Should -Be 'direct'
        $global:VmCalls | Should -Be @('Export-VApp db01')
    }

    It 'can skip quiescing' {
        & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir -Quiesce $false | Out-Null
        $global:VmCalls[0] | Should -Be 'New-Snapshot quiesce=False'
    }

    It 'cleans up clone, snapshot and the partial folder when the export fails' {
        $global:VmFail['Export'] = $true

        { & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir } | Should -Throw '*simulated export failure*'

        ($global:VmCalls | Where-Object { $_ -like 'Remove-VM *' }).Count | Should -Be 1
        $global:VmCalls | Should -Contain 'Remove-Snapshot'
        @(Get-ChildItem (Join-Path $backupDir 'app01') -Force).Count | Should -Be 0
    }

    It 'fails loudly when the snapshot cannot be removed, but keeps the good export' {
        $global:VmFail['RemoveSnapshot'] = $true

        { & (Join-Path $root 'vmware-backup.ps1') -VMName 'app01' -BackupPath $backupDir } | Should -Throw '*snapshot locked*'

        @(Get-BackupSet -Path (Join-Path $backupDir 'app01') -Directory).Count | Should -Be 1
    }
}
