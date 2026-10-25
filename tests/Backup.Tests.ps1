# End-to-end runs of backup.ps1 and check-backup.ps1 with FireBird (fake gbak) and
# Oracle (fake expdp). VMware is covered in Workers.Tests.ps1.

BeforeAll {
    $root  = Split-Path $PSScriptRoot -Parent
    $fakes = Join-Path $PSScriptRoot 'fakes'
    Import-Module (Join-Path $root 'lib/BackupCommon.psm1') -Force

    function New-TestSetup {
        param([switch]$WithOracle, [switch]$WithEncryption, [switch]$WithOffsite)
        $base  = Join-Path $TestDrive ([guid]::NewGuid())
        $store = Join-Path $base 'secrets'
        $secure = [System.Net.NetworkCredential]::new('', 'masterkey').SecurePassword
        $cred = New-Object System.Management.Automation.PSCredential('SYSDBA', $secure)
        Set-BackupCredential -Name 'fb' -Credential $cred -StorePath $store | Out-Null
        Set-BackupCredential -Name 'ora' -Credential $cred -StorePath $store | Out-Null
        $passphrase = New-Object System.Management.Automation.PSCredential('x', [System.Net.NetworkCredential]::new('', 'correct horse battery staple').SecurePassword)
        Set-BackupCredential -Name 'enc' -Credential $passphrase -StorePath $store | Out-Null
        $dumpDir = New-Item -ItemType Directory (Join-Path $base 'dpdump')

        $config = [ordered]@{
            LogPath             = Join-Path $base 'logs'
            CredentialStorePath = $store
            MinFreeSpaceGB      = 0
            Retention           = @{ Days = 14; MinKeep = 2 }
            Monitoring          = @{ MaxBackupAgeHours = 26 }
            FireBird            = @{
                Enabled = $true; GbakPath = (Join-Path $fakes 'gbak.ps1'); BackupPath = (Join-Path $base 'fb')
                Databases = @(
                    @{ Name = 'db1'; Path = 'C:\db1.fdb'; CredentialName = 'fb' },
                    @{ Name = 'db2'; Path = 'C:\db2.fdb'; CredentialName = 'fb' }
                )
            }
            Oracle              = @{
                Enabled = [bool]$WithOracle; ExpdpPath = (Join-Path $fakes 'expdp.ps1'); ImpdpPath = (Join-Path $fakes 'impdp.ps1')
                Label = 'orcl'; TnsName = 'ORCL'
                DirectoryObject = 'DATA_PUMP_DIR'; DumpDirectoryPath = $dumpDir.FullName
                BackupPath = (Join-Path $base 'ora'); UseWallet = $false; CredentialName = 'ora'
            }
            Encryption          = @{ Enabled = [bool]$WithEncryption; CredentialName = 'enc'; Iterations = 100000 }
            Offsite             = @{ Enabled = [bool]$WithOffsite; Path = (Join-Path $base 'offsite'); Retention = @{ Days = 30; MinKeep = 1 } }
        }
        $path = Join-Path $base 'config.json'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        $env:FAKE_DUMP_DIR = $dumpDir.FullName
        [pscustomobject]@{
            Base = $base; ConfigPath = $path; FbPath = $config.FireBird.BackupPath; OraPath = $config.Oracle.BackupPath
            OffsitePath = $config.Offsite.Path; Passphrase = $passphrase
        }
    }

    function Invoke-Script([string]$Name, [hashtable]$Arguments) {
        $output = & (Join-Path $root $Name) @Arguments 6>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
}

Describe 'backup.ps1' {
    AfterEach {
        Remove-Item Env:FAKE_GBAK_FAIL, Env:FAKE_DUMP_DIR, Env:FAKE_EXPDP_EXIT -ErrorAction SilentlyContinue
    }

    It 'backs up every database, writes a log and exits 0' {
        $t = New-TestSetup -WithOracle

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 0
        @(Get-BackupSet -Path $t.FbPath -Prefix 'db1').Count | Should -Be 1
        @(Get-BackupSet -Path $t.FbPath -Prefix 'db2').Count | Should -Be 1
        @(Get-BackupSet -Path $t.OraPath -Prefix 'orcl').Count | Should -Be 1
        $log = Get-Content (Get-ChildItem (Join-Path $t.Base 'logs') -Filter 'backup_*.log').FullName -Raw
        $log | Should -Match '3 of 3 backups succeeded'
        foreach ($set in @(Get-BackupSet -Path $t.FbPath -Prefix 'db1') + @(Get-BackupSet -Path $t.OraPath -Prefix 'orcl')) {
            @($set.Items.Name -like '*.sha256').Count | Should -Be 1
        }
    }

    It 'encrypts every backup and copies it offsite, verified' {
        $t = New-TestSetup -WithOracle -WithEncryption -WithOffsite

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 0
        ($run.Output -join "`n") | Should -Match '3 of 3 backups succeeded, 3 of 3 offsite copies'
        @(Get-ChildItem $t.FbPath -Filter '*.fbk').Count | Should -Be 0
        @(Get-ChildItem $t.FbPath -Filter '*.fbk.enc').Count | Should -Be 2
        @(Get-ChildItem $t.OraPath -Filter '*.dmp.enc').Count | Should -Be 1
        foreach ($sub in 'FireBird', 'Oracle') {
            foreach ($m in Get-ChildItem (Join-Path $t.OffsitePath $sub) -Filter '*.sha256') {
                @(Test-BackupManifest -Path $m.FullName).Count | Should -Be 0
            }
        }
        @(Get-ChildItem (Join-Path $t.OffsitePath 'FireBird') -Filter '*.fbk.enc').Count | Should -Be 2

        $enc = (Get-ChildItem (Join-Path $t.OffsitePath 'FireBird') -Filter 'db1_*.fbk.enc').FullName
        $plain = Join-Path $t.Base 'restored.fbk'
        Unprotect-BackupFile -Path $enc -Destination $plain -Credential $t.Passphrase
        Get-Content $plain | Should -Be 'fake -b output'
    }

    It 'aborts with exit 2 instead of writing unencrypted backups when the passphrase is missing' {
        $t = New-TestSetup -WithEncryption
        Remove-Item (Join-Path $t.Base 'secrets/enc.cred.xml')

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 2
        Test-Path $t.FbPath | Should -BeFalse
    }

    It 'reports an unreachable offsite store as a failure but keeps the local backups' {
        $t = New-TestSetup -WithOffsite
        $json = Get-Content $t.ConfigPath -Raw | ConvertFrom-Json
        $json.Offsite.Path = Join-Path $t.ConfigPath 'share'   # below a file: cannot exist
        $json | ConvertTo-Json -Depth 10 | Set-Content $t.ConfigPath

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 1
        ($run.Output -join "`n") | Should -Match 'FireBird/db1 \(offsite\): .*not reachable'
        @(Get-BackupSet -Path $t.FbPath -Prefix 'db1').Count | Should -Be 1
    }

    It 'exits 1 and names the failed targets when a backup fails' {
        $t = New-TestSetup
        $env:FAKE_GBAK_FAIL = '-b'

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 1
        ($run.Output -join "`n") | Should -Match 'FireBird/db1: .*exit code 1'
        ($run.Output -join "`n") | Should -Match '0 of 2 backups succeeded'
    }

    It 'does not apply retention for a target whose backup failed' {
        $t = New-TestSetup
        New-Item -ItemType Directory $t.FbPath | Out-Null
        foreach ($d in 30, 31, 32) {
            Set-Content (Join-Path $t.FbPath ('db1_{0}.fbk' -f (Get-Date).AddDays(-$d).ToString('yyyyMMdd_HHmmss'))) 'old'
        }
        $env:FAKE_GBAK_FAIL = '-b'

        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null

        @(Get-BackupSet -Path $t.FbPath -Prefix 'db1').Count | Should -Be 3
    }

    It 'applies retention after a successful backup, keeping MinKeep copies' {
        $t = New-TestSetup
        New-Item -ItemType Directory $t.FbPath | Out-Null
        foreach ($d in 30, 31, 32) {
            Set-Content (Join-Path $t.FbPath ('db1_{0}.fbk' -f (Get-Date).AddDays(-$d).ToString('yyyyMMdd_HHmmss'))) 'old'
        }

        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null

        # new backup + newest old one (MinKeep = 2)
        @(Get-BackupSet -Path $t.FbPath -Prefix 'db1').Count | Should -Be 2
    }

    It 'exits 2 on an invalid config without touching anything' {
        $path = Join-Path $TestDrive 'invalid.json'
        '{ "MinFreeSpaceGB": 0 }' | Set-Content $path

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $path }

        $run.ExitCode | Should -Be 2
        ($run.Output -join "`n") | Should -Match 'Retention.Days'
    }

    It 'exits 2 when there is not enough free disk space' {
        $t = New-TestSetup
        $json = Get-Content $t.ConfigPath -Raw | ConvertFrom-Json
        $json.MinFreeSpaceGB = 1e9
        $json | ConvertTo-Json -Depth 10 | Set-Content $t.ConfigPath

        $run = Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $run.ExitCode | Should -Be 2
        Test-Path (Join-Path $t.FbPath '*.fbk') | Should -BeFalse
    }
}

Describe 'check-backup.ps1' {
    AfterEach {
        Remove-Item Env:FAKE_GBAK_FAIL, Env:FAKE_DUMP_DIR, Env:FAKE_EXPDP_EXIT -ErrorAction SilentlyContinue
    }

    It 'reports OK after a successful backup run' {
        $t = New-TestSetup -WithOracle
        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null

        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath; AsJson = $true }

        $check.ExitCode | Should -Be 0
        $result = $check.Output -join '' | ConvertFrom-Json
        $result.status | Should -Be 'ok'
        $result.checked | Should -Be 3
    }

    It 'checks the offsite copies too' {
        $t = New-TestSetup -WithOffsite
        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null
        Get-ChildItem (Join-Path $t.OffsitePath 'FireBird') -Filter 'db2_*' | Remove-Item

        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath; AsJson = $true }

        $check.ExitCode | Should -Be 1
        $result = $check.Output -join '' | ConvertFrom-Json
        $result.checked | Should -Be 4
        @($result.problems) | Should -Be @('Offsite/FireBird/db2: no backups found in ' + (Join-Path $t.OffsitePath 'FireBird'))
    }

    It 'detects a backup that was damaged after it was written' {
        $t = New-TestSetup -WithEncryption
        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null
        $file = (Get-ChildItem $t.FbPath -Filter 'db1_*.fbk.enc').FullName
        $bytes = [IO.File]::ReadAllBytes($file); $bytes[70] = $bytes[70] -bxor 0xFF; [IO.File]::WriteAllBytes($file, $bytes)

        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath; AsJson = $true }

        $check.ExitCode | Should -Be 1
        ($check.Output -join '' | ConvertFrom-Json).problems | Should -Match '^FireBird/db1: checksum verification failed: db1_\d{8}_\d{6}\.fbk\.enc: SHA256 mismatch$'
    }

    It 'flags a database whose backups stopped while the others continue' {
        $t = New-TestSetup
        Invoke-Script 'backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath } | Out-Null
        Get-ChildItem $t.FbPath -Filter 'db2_*' | Remove-Item

        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath; AsJson = $true }

        $check.ExitCode | Should -Be 1
        $result = $check.Output -join '' | ConvertFrom-Json
        @($result.problems).Count | Should -Be 1
        $result.problems[0] | Should -Match '^FireBird/db2: no backups'
    }

    It 'flags stale backups' {
        $t = New-TestSetup
        New-Item -ItemType Directory $t.FbPath | Out-Null
        foreach ($db in 'db1', 'db2') {
            Set-Content (Join-Path $t.FbPath ('{0}_{1}.fbk' -f $db, (Get-Date).AddDays(-3).ToString('yyyyMMdd_HHmmss'))) 'old'
        }

        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = $t.ConfigPath }

        $check.ExitCode | Should -Be 1
        ($check.Output -join "`n") | Should -Match 'BACKUP CHECK FAILED \(2 of 2\)'
    }

    It 'exits 2 on a missing config' {
        $check = Invoke-Script 'check-backup.ps1' -Arguments @{ ConfigPath = (Join-Path $TestDrive 'none.json'); AsJson = $true }
        $check.ExitCode | Should -Be 2
        ($check.Output -join '' | ConvertFrom-Json).status | Should -Be 'error'
    }
}
