BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'lib/BackupCommon.psm1') -Force

    function New-BackupFile([string]$Dir, [string]$Name, [string]$Content = 'x') {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -Path (Join-Path $Dir $Name) -Value $Content
    }

    function Get-Stamp([double]$DaysAgo) {
        (Get-Date).AddDays(-$DaysAgo).ToString('yyyyMMdd_HHmmss')
    }

    function Get-ExampleConfig {
        Get-Content (Join-Path $root 'config.example.json') -Raw | ConvertFrom-Json
    }
}

Describe 'Get-BackupSet' {
    It 'groups files of one backup by timestamp and sorts newest first' {
        $dir = Join-Path $TestDrive 'sets'
        New-BackupFile $dir 'orcl_20260101_020000.dmp'
        New-BackupFile $dir 'orcl_20260101_020000.log'
        New-BackupFile $dir 'orcl_20260102_020000.dmp'

        $sets = Get-BackupSet -Path $dir -Prefix 'orcl'

        $sets.Count | Should -Be 2
        $sets[0].Timestamp | Should -Be ([datetime]'2026-01-02 02:00:00')
        $sets[1].Items.Count | Should -Be 2
    }

    It 'ignores foreign files, in-progress files and other prefixes' {
        $dir = Join-Path $TestDrive 'foreign'
        New-BackupFile $dir 'db_20260101_020000.fbk'
        New-BackupFile $dir '.db_20260102_020000.fbk'      # in progress
        New-BackupFile $dir 'db_2_20260103_020000.fbk'     # another database
        New-BackupFile $dir 'important.fbk'
        New-BackupFile $dir 'db_20260104.fbk'

        $sets = Get-BackupSet -Path $dir -Prefix 'db'

        $sets.Count | Should -Be 1
        $sets[0].Items[0].Name | Should -Be 'db_20260101_020000.fbk'
    }

    It 'orders directories by the name, not by LastWriteTime' {
        $dir = Join-Path $TestDrive 'vm'
        $old = New-Item -ItemType Directory -Path (Join-Path $dir '20260101_020000') -Force
        New-Item -ItemType Directory -Path (Join-Path $dir '20260105_020000') -Force | Out-Null
        $old.LastWriteTime = Get-Date   # what NTFS does when retention deletes files inside

        (Get-BackupSet -Path $dir -Directory)[0].Items[0].Name | Should -Be '20260105_020000'
    }

    It 'returns nothing for a missing path' {
        @(Get-BackupSet -Path (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
}

Describe 'Remove-ExpiredBackup' {
    It 'removes sets older than the retention period' {
        $dir = Join-Path $TestDrive 'ret1'
        foreach ($d in 1, 2, 3, 20, 30) { New-BackupFile $dir "db_$(Get-Stamp $d).fbk" }

        $removed = @(Remove-ExpiredBackup -Path $dir -Prefix 'db' -RetentionDays 14 -MinKeep 1)

        $removed.Count | Should -Be 2
        @(Get-ChildItem $dir).Count | Should -Be 3
    }

    It 'always keeps MinKeep newest sets even when all of them are expired' {
        $dir = Join-Path $TestDrive 'ret2'
        $stamps = foreach ($d in 20, 21, 22, 23, 24) { Get-Stamp $d }
        foreach ($st in $stamps) { New-BackupFile $dir "db_$st.fbk" }

        Remove-ExpiredBackup -Path $dir -Prefix 'db' -RetentionDays 14 -MinKeep 3 | Out-Null

        $left = @(Get-ChildItem $dir | Sort-Object Name -Descending)
        $left.Count | Should -Be 3
        $left[0].Name | Should -Be "db_$($stamps[0]).fbk"
    }

    It 'counts a backup set (dump + log) as one copy for MinKeep' {
        $dir = Join-Path $TestDrive 'ret3'
        foreach ($d in 20, 21, 22) {
            $s = Get-Stamp $d
            New-BackupFile $dir "orcl_$s.dmp"
            New-BackupFile $dir "orcl_$s.log"
        }

        Remove-ExpiredBackup -Path $dir -Prefix 'orcl' -RetentionDays 7 -MinKeep 2 | Out-Null

        @(Get-ChildItem $dir).Count | Should -Be 4
    }

    It 'never touches files it did not create' {
        $dir = Join-Path $TestDrive 'ret4'
        New-BackupFile $dir 'manual_copy.fbk'
        New-BackupFile $dir "other_$(Get-Stamp 100).fbk"
        (Get-Item (Join-Path $dir 'manual_copy.fbk')).LastWriteTime = (Get-Date).AddYears(-1)

        Remove-ExpiredBackup -Path $dir -Prefix 'db' -RetentionDays 1 -MinKeep 1 | Out-Null

        @(Get-ChildItem $dir).Count | Should -Be 2
    }

    It 'removes whole directories in directory mode' {
        $dir = Join-Path $TestDrive 'ret5'
        foreach ($d in 1, 40) { New-BackupFile (Join-Path $dir (Get-Stamp $d)) 'vm.ovf' }

        Remove-ExpiredBackup -Path $dir -Directory -RetentionDays 14 -MinKeep 1 | Out-Null

        @(Get-ChildItem $dir).Count | Should -Be 1
    }

    It 'does nothing when RetentionDays is 0' {
        $dir = Join-Path $TestDrive 'ret6'
        foreach ($d in 100, 200) { New-BackupFile $dir "db_$(Get-Stamp $d).fbk" }

        Remove-ExpiredBackup -Path $dir -Prefix 'db' -RetentionDays 0 -MinKeep 1 | Out-Null

        @(Get-ChildItem $dir).Count | Should -Be 2
    }

    It 'honours -WhatIf' {
        $dir = Join-Path $TestDrive 'ret7'
        foreach ($d in 1, 40) { New-BackupFile $dir "db_$(Get-Stamp $d).fbk" }

        Remove-ExpiredBackup -Path $dir -Prefix 'db' -RetentionDays 14 -MinKeep 1 -WhatIf | Out-Null

        @(Get-ChildItem $dir).Count | Should -Be 2
    }
}

Describe 'Test-BackupFreshness' {
    It 'returns $null for a fresh, non-empty backup' {
        $dir = Join-Path $TestDrive 'fresh'
        New-BackupFile $dir "db_$(Get-Stamp 0.1).fbk"
        Test-BackupFreshness -Path $dir -Prefix 'db' -MaxAgeHours 26 -Label 'db' -RequiredPattern '*.fbk' | Should -BeNullOrEmpty
    }

    It 'reports a stale backup' {
        $dir = Join-Path $TestDrive 'stale'
        New-BackupFile $dir "db_$(Get-Stamp 3).fbk"
        Test-BackupFreshness -Path $dir -Prefix 'db' -MaxAgeHours 26 -Label 'db' -RequiredPattern '*.fbk' | Should -Match 'old'
    }

    It 'reports an empty backup file' {
        $dir = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory $dir | Out-Null
        New-Item -ItemType File (Join-Path $dir "db_$(Get-Stamp 0.1).fbk") | Out-Null
        Test-BackupFreshness -Path $dir -Prefix 'db' -MaxAgeHours 26 -Label 'db' -RequiredPattern '*.fbk' | Should -Match 'empty'
    }

    It 'reports a VM backup folder without an OVF' {
        $dir = Join-Path $TestDrive 'noovf'
        New-BackupFile (Join-Path $dir (Get-Stamp 0.1)) 'disk.vmdk'
        Test-BackupFreshness -Path $dir -Directory -MaxAgeHours 26 -Label 'vm' -RequiredPattern '*.ovf' | Should -Match 'no \*\.ovf'
    }

    It 'finds the OVF in the export subfolder' {
        $dir = Join-Path $TestDrive 'ovf'
        New-BackupFile (Join-Path (Join-Path $dir (Get-Stamp 0.1)) 'vm-clone') 'vm-clone.ovf'
        Test-BackupFreshness -Path $dir -Directory -MaxAgeHours 26 -Label 'vm' -RequiredPattern '*.ovf' | Should -BeNullOrEmpty
    }

    It 'reports a missing directory and a directory without backups' {
        Test-BackupFreshness -Path (Join-Path $TestDrive 'missing') -MaxAgeHours 26 -Label 'x' -RequiredPattern '*' | Should -Match 'does not exist'
        $dir = New-Item -ItemType Directory (Join-Path $TestDrive 'nothing')
        Test-BackupFreshness -Path $dir.FullName -Prefix 'db' -MaxAgeHours 26 -Label 'x' -RequiredPattern '*' | Should -Match 'no backups'
    }
}

Describe 'Test-BackupConfig' {
    It 'accepts config.example.json' {
        Test-BackupConfig -Config (Get-ExampleConfig) | Should -BeNullOrEmpty
    }

    It 'requires MinKeep >= 1' {
        $c = Get-ExampleConfig
        $c.Retention.MinKeep = 0
        Test-BackupConfig -Config $c | Should -Contain 'Retention.MinKeep must be an integer >= 1'
    }

    It 'reports missing fields of an enabled component' {
        $c = Get-ExampleConfig
        $c.FireBird.PSObject.Properties.Remove('GbakPath')
        $c.FireBird.Databases[0].CredentialName = ''
        $problems = Test-BackupConfig -Config $c
        $problems | Should -Contain 'FireBird.GbakPath is required'
        $problems | Should -Contain 'FireBird.Databases[0].CredentialName is required'
    }

    It 'rejects duplicate and unsafe database names' {
        $c = Get-ExampleConfig
        $db = $c.FireBird.Databases[0]
        $c.FireBird.Databases = @($db, $db, [pscustomobject]@{ Name = 'a b'; Path = 'x'; CredentialName = 'y' })
        $problems = Test-BackupConfig -Config $c
        ($problems -match 'more than once').Count | Should -Be 1
        ($problems -match "'a b' may only contain").Count | Should -Be 1
    }

    It 'does not validate disabled components' {
        $c = Get-ExampleConfig
        $c.Oracle.Enabled = $false
        $c.Oracle.PSObject.Properties.Remove('TnsName')
        Test-BackupConfig -Config $c | Should -BeNullOrEmpty
    }

    It 'requires the Oracle credential only without a wallet' {
        $c = Get-ExampleConfig
        $c.Oracle.Enabled = $true
        $c.Oracle.CredentialName = ''
        Test-BackupConfig -Config $c | Should -Contain 'Oracle.CredentialName is required'
        $c.Oracle.UseWallet = $true
        Test-BackupConfig -Config $c | Should -BeNullOrEmpty
    }

    It 'rejects an unknown Data Pump compression mode' {
        $c = Get-ExampleConfig
        $c.Oracle.Enabled = $true
        $c.Oracle.Compression = 'MAX'
        (Test-BackupConfig -Config $c) -match 'Compression' | Should -Not -BeNullOrEmpty
    }

    It 'complains when nothing is enabled' {
        $c = Get-ExampleConfig
        $c.VMware.Enabled = $false
        $c.FireBird.Enabled = $false
        Test-BackupConfig -Config $c | Should -Contain 'Nothing to do: enable at least one of VMware, FireBird, Oracle'
    }

    It 'Get-BackupConfig lists all problems in one error' {
        $c = Get-ExampleConfig
        $c.MinFreeSpaceGB = -1
        $c.Retention.MinKeep = 0
        $path = Join-Path $TestDrive 'bad.json'
        $c | ConvertTo-Json -Depth 10 | Set-Content $path
        { Get-BackupConfig -Path $path } | Should -Throw '*MinFreeSpaceGB*MinKeep*'
    }

    It 'Get-BackupConfig reports invalid JSON and a missing file clearly' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content $path '{ "a": '
        { Get-BackupConfig -Path $path } | Should -Throw '*not valid JSON*'
        { Get-BackupConfig -Path (Join-Path $TestDrive 'none.json') } | Should -Throw '*config.example.json*'
    }
}

Describe 'Credentials' {
    It 'round-trips a credential through the store' {
        $store = Join-Path $TestDrive 'secrets'
        $secure = [System.Net.NetworkCredential]::new('', 'p@ss "word"').SecurePassword
        $cred = New-Object System.Management.Automation.PSCredential('backup', $secure)

        Set-BackupCredential -Name 'db' -Credential $cred -StorePath $store | Out-Null
        $loaded = Get-BackupCredential -Name 'db' -StorePath $store

        $loaded.UserName | Should -Be 'backup'
        $loaded.GetNetworkCredential().Password | Should -Be 'p@ss "word"'
    }

    It 'explains how to fix a missing credential' {
        { Get-BackupCredential -Name 'nope' -StorePath $TestDrive } | Should -Throw '*Set-BackupCredentials.ps1*'
    }
}

Describe 'Invoke-NativeCommand' {
    It 'returns the exit code and output without throwing on failure' {
        $env:FAKE_GBAK_FAIL = '-b'
        try {
            $r = Invoke-NativeCommand -FilePath (Join-Path $PSScriptRoot 'fakes/gbak.ps1') -ArgumentList @('-b', (Join-Path $TestDrive 'x.fbk'))
        }
        finally { Remove-Item Env:FAKE_GBAK_FAIL }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Contain 'ERROR: simulated failure'
    }
}

Describe 'Encryption' {
    BeforeAll {
        $secure = [System.Net.NetworkCredential]::new('', 'correct horse battery staple').SecurePassword
        $key    = New-Object System.Management.Automation.PSCredential('x', $secure)
        $wrong  = New-Object System.Management.Automation.PSCredential('x', [System.Net.NetworkCredential]::new('', 'wrong').SecurePassword)
    }
    BeforeEach {
        $dir   = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $dir | Out-Null
        $plain = Join-Path $dir 'data.bin'
        $bytes = New-Object byte[] (3MB + 5)
        (New-Object Random 42).NextBytes($bytes)
        [IO.File]::WriteAllBytes($plain, $bytes)
    }

    It 'implements PBKDF2-HMAC-SHA256 correctly (RFC 7914 test vector)' {
        $dk = [BackupAutomation.FileCrypto]::Pbkdf2Sha256([Text.Encoding]::ASCII.GetBytes('passwd'), [Text.Encoding]::ASCII.GetBytes('salt'), 1, 64)
        -join ($dk | ForEach-Object { $_.ToString('x2') }) |
            Should -Be '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783'
    }

    It 'round-trips a file' {
        Protect-BackupFile -Path $plain -Destination "$plain.enc" -Credential $key -Iterations 1000
        Unprotect-BackupFile -Path "$plain.enc" -Destination "$plain.out" -Credential $key

        (Get-FileHash "$plain.out").Hash | Should -Be (Get-FileHash $plain).Hash
        (Get-FileHash "$plain.enc").Hash | Should -Not -Be (Get-FileHash $plain).Hash
    }

    It 'uses a fresh salt and IV for every file' {
        Protect-BackupFile -Path $plain -Destination "$plain.1.enc" -Credential $key -Iterations 1000
        Protect-BackupFile -Path $plain -Destination "$plain.2.enc" -Credential $key -Iterations 1000
        (Get-FileHash "$plain.1.enc").Hash | Should -Not -Be (Get-FileHash "$plain.2.enc").Hash
    }

    It 'rejects a wrong passphrase without leaving output' {
        Protect-BackupFile -Path $plain -Destination "$plain.enc" -Credential $key -Iterations 1000
        { Unprotect-BackupFile -Path "$plain.enc" -Destination "$plain.out" -Credential $wrong } | Should -Throw '*Wrong passphrase*'
        Test-Path "$plain.out" | Should -BeFalse
    }

    It 'detects a modified byte anywhere in the file and leaves no output' {
        Protect-BackupFile -Path $plain -Destination "$plain.enc" -Credential $key -Iterations 1000
        foreach ($offset in 100, 2MB, -1) {
            $b = [IO.File]::ReadAllBytes("$plain.enc")
            $i = if ($offset -lt 0) { $b.Length - 1 } else { $offset }
            $b[$i] = $b[$i] -bxor 0x01
            [IO.File]::WriteAllBytes("$plain.bad", $b)
            { Unprotect-BackupFile -Path "$plain.bad" -Destination "$plain.out" -Credential $key } | Should -Throw '*Integrity check failed*'
            Test-Path "$plain.out" | Should -BeFalse
        }
    }

    It 'detects a truncated file' {
        Protect-BackupFile -Path $plain -Destination "$plain.enc" -Credential $key -Iterations 1000
        $b = [IO.File]::ReadAllBytes("$plain.enc")
        [IO.File]::WriteAllBytes("$plain.short", $b[0..($b.Length - 17)])
        { Unprotect-BackupFile -Path "$plain.short" -Credential $key } | Should -Throw
    }

    It 'never overwrites an existing target' {
        Set-Content "$plain.enc" 'keep me'
        { Protect-BackupFile -Path $plain -Destination "$plain.enc" -Credential $key -Iterations 1000 } | Should -Throw '*already exists*'
        Get-Content "$plain.enc" | Should -Be 'keep me'
    }

    It 'handles an empty file' {
        $empty = Join-Path $dir 'empty.bin'
        New-Item -ItemType File $empty | Out-Null
        Protect-BackupFile -Path $empty -Destination "$empty.enc" -Credential $key -Iterations 1000
        Unprotect-BackupFile -Path "$empty.enc" -Destination "$empty.out" -Credential $key
        (Get-Item "$empty.out").Length | Should -Be 0
    }
}

Describe 'SHA256 manifests' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-BackupFile $dir 'a.fbk' 'alpha'
        New-BackupFile (Join-Path $dir 'sub') 'b.vmdk' 'bravo'
        $manifest = Join-Path $dir 'SHA256SUMS'
        Write-BackupManifest -Path $manifest -Entry @(
            [pscustomobject]@{ Name = 'a.fbk'; Path = (Join-Path $dir 'a.fbk') }
            [pscustomobject]@{ Name = 'sub/b.vmdk'; Path = (Join-Path $dir 'sub/b.vmdk') }
        )
    }

    It 'writes sha256sum-compatible lines (LF, no BOM)' {
        $raw = [IO.File]::ReadAllBytes($manifest)
        $raw[0] | Should -Not -Be 0xEF
        [Text.Encoding]::UTF8.GetString($raw) | Should -Not -Match "`r"
        (Get-Content $manifest)[0] | Should -Be ("{0}  a.fbk" -f (Get-FileHash (Join-Path $dir 'a.fbk')).Hash.ToLowerInvariant())
    }

    It 'passes for intact files' {
        @(Test-BackupManifest -Path $manifest).Count | Should -Be 0
    }

    It 'reports modified and missing files' {
        Set-Content (Join-Path $dir 'a.fbk') 'tampered'
        Remove-Item (Join-Path $dir 'sub/b.vmdk')
        $problems = @(Test-BackupManifest -Path $manifest)
        $problems | Should -Contain 'a.fbk: SHA256 mismatch'
        $problems | Should -Contain 'sub/b.vmdk: missing'
    }

    It 'refuses paths that leave the backup folder' {
        Add-Content $manifest ('0' * 64 + '  ../outside.txt')
        @(Test-BackupManifest -Path $manifest) | Should -Contain 'unsafe path in manifest: ../outside.txt'
    }

    It 'makes Test-BackupFreshness detect silent corruption' {
        $set = Join-Path $TestDrive "fresh_$([guid]::NewGuid())"
        $stamp = Get-Stamp 0.1
        New-BackupFile $set "db_$stamp.fbk" 'data'
        Write-BackupManifest -Path (Join-Path $set "db_$stamp.sha256") -Entry @([pscustomobject]@{ Name = "db_$stamp.fbk"; Path = (Join-Path $set "db_$stamp.fbk") })

        Test-BackupFreshness -Path $set -Prefix 'db' -MaxAgeHours 24 -Label 'db' -RequiredPattern '*.fbk' -VerifyChecksums | Should -BeNullOrEmpty
        Set-Content (Join-Path $set "db_$stamp.fbk") 'bit rot'
        Test-BackupFreshness -Path $set -Prefix 'db' -MaxAgeHours 24 -Label 'db' -RequiredPattern '*.fbk' -VerifyChecksums |
            Should -Match 'checksum verification failed.*SHA256 mismatch'
    }

    It 'reports a newest set without manifest when checksums are verified' {
        $set = Join-Path $TestDrive "nomani_$([guid]::NewGuid())"
        New-BackupFile $set "db_$(Get-Stamp 0.1).fbk"
        Test-BackupFreshness -Path $set -Prefix 'db' -MaxAgeHours 24 -Label 'db' -RequiredPattern '*.fbk' -VerifyChecksums |
            Should -Match 'no SHA256 manifest'
    }
}

Describe 'Complete-BackupFileSet' {
    It 'renames to final names only at the end and cleans up on failure' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-BackupFile $dir '.x_20260101_020000.fbk' 'data'
        $missing = [pscustomobject]@{ Source = (Join-Path $dir 'does-not-exist'); Name = 'x_20260101_020000.log'; Encrypt = $false }
        $good    = [pscustomobject]@{ Source = (Join-Path $dir '.x_20260101_020000.fbk'); Name = 'x_20260101_020000.fbk'; Encrypt = $false }

        { Complete-BackupFileSet -Directory $dir -BaseName 'x_20260101_020000' -File $good, $missing } | Should -Throw
        @(Get-ChildItem $dir -Force).Count | Should -Be 0
    }
}

Describe 'Copy-BackupSetToOffsite' {
    BeforeAll {
        function New-ManifestSet([string]$Dir, [string]$Prefix, [string]$Stamp) {
            New-BackupFile $Dir "${Prefix}_$Stamp.fbk" "backup $Stamp"
            Write-BackupManifest -Path (Join-Path $Dir "${Prefix}_$Stamp.sha256") -Entry @(
                [pscustomobject]@{ Name = "${Prefix}_$Stamp.fbk"; Path = (Join-Path $Dir "${Prefix}_$Stamp.fbk") })
        }
    }
    BeforeEach {
        $local  = Join-Path $TestDrive "local_$([guid]::NewGuid())"
        $remote = Join-Path $TestDrive "remote_$([guid]::NewGuid())"
    }

    It 'copies only the newest set into an empty store and verifies it there' {
        New-ManifestSet $local 'db' '20260101_020000'
        New-ManifestSet $local 'db' '20260102_020000'

        $r = Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote

        $r.Copied | Should -Be 1
        @(Get-ChildItem $remote -Force).Name | Sort-Object | Should -Be @('db_20260102_020000.fbk', 'db_20260102_020000.sha256')
        @(Test-BackupManifest -Path (Join-Path $remote 'db_20260102_020000.sha256')).Count | Should -Be 0
    }

    It 'catches up on every set missed while the store was unreachable' {
        New-ManifestSet $local 'db' '20260101_020000'
        Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote | Out-Null
        New-ManifestSet $local 'db' '20260102_020000'
        New-ManifestSet $local 'db' '20260103_020000'

        (Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote).Copied | Should -Be 2
        @(Get-BackupSet -Path $remote -Prefix 'db').Count | Should -Be 3
        (Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote).Copied | Should -Be 0
    }

    It 'refuses a set that does not match its manifest and leaves nothing behind' {
        New-ManifestSet $local 'db' '20260101_020000'
        Set-Content (Join-Path $local 'db_20260101_020000.fbk') 'corrupted after the backup'

        { Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote } | Should -Throw '*failed verification*SHA256 mismatch*'
        @(Get-ChildItem $remote -Force).Count | Should -Be 0
    }

    It 'refuses a set without manifest' {
        New-BackupFile $local 'db_20260101_020000.fbk'
        { Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote } | Should -Throw '*no SHA256 manifest*'
    }

    It 'copies VM export folders and removes leftovers of an interrupted copy' {
        $vmSet = Join-Path $local '20260101_020000'
        New-BackupFile (Join-Path $vmSet 'app01') 'app01.ovf' '<Envelope/>'
        Complete-BackupDirectory -Path $vmSet
        New-Item -ItemType Directory (Join-Path $remote '.20251231_020000') -Force | Out-Null

        Copy-BackupSetToOffsite -Path $local -Directory -Destination $remote | Out-Null

        @(Get-ChildItem $remote -Force).Name | Should -Be @('20260101_020000')
        Test-BackupFreshness -Path $remote -Directory -MaxAgeHours 1e6 -Label 'vm' -RequiredPattern '*.ovf' -VerifyChecksums | Should -BeNullOrEmpty
    }

    It 'checks the free space on the destination first' {
        New-ManifestSet $local 'db' '20260101_020000'
        { Copy-BackupSetToOffsite -Path $local -Prefix 'db' -Destination $remote -MinFreeSpaceGB 1e9 } | Should -Throw '*Not enough free space for offsite copy*'
    }
}

Describe 'Free space' {
    It 'works for a folder that does not exist yet' {
        Get-FreeSpaceGB -Path (Join-Path $TestDrive 'not/yet/there') | Should -BeGreaterThan 0
    }

    It 'Assert-FreeSpace explains what was needed' {
        { Assert-FreeSpace -Path $TestDrive -RequiredGB 1e9 -ReserveGB 5 -Purpose 'test restore' } |
            Should -Throw '*Not enough free space for test restore*reserve*'
        { Assert-FreeSpace -Path $TestDrive -RequiredGB 0 } | Should -Not -Throw
    }
}

Describe 'Alert text' {
    It 'leaves short messages alone' {
        Format-AlertText -Text 'all good' -MaxLength 4000 | Should -Be 'all good'
    }

    It 'shortens long messages to the limit and says how much is missing' {
        $text = 'x' * 10000
        $short = Format-AlertText -Text $text -MaxLength 4000
        $short.Length | Should -BeLessOrEqual 4000
        $short | Should -Match 'truncated, \d+ more characters'
        $missing = [int]([regex]::Match($short, 'truncated, (\d+) more').Groups[1].Value)
        ($short.IndexOf("`n...") + $missing) | Should -Be 10000
    }

    It 'does not split a surrogate pair' {
        $text = ('a' * 3940) + ([char]::ConvertFromUtf32(0x1F4BE) * 200)
        $short = Format-AlertText -Text $text -MaxLength 4000
        $body = $short.Substring(0, $short.IndexOf("`n..."))
        [char]::IsHighSurrogate($body[-1]) | Should -BeFalse
    }

    It 'Send-TelegramAlert never sends more than 4096 characters' {
        $store = Join-Path $TestDrive "tg_$([guid]::NewGuid())"
        $cred = New-Object System.Management.Automation.PSCredential('bot', [System.Net.NetworkCredential]::new('', '123:token').SecurePassword)
        Set-BackupCredential -Name 'tg' -Credential $cred -StorePath $store | Out-Null
        $config = [pscustomobject]@{ Telegram = [pscustomobject]@{ Enabled = $true; CredentialName = 'tg'; ChatId = '1' } }
        Mock -ModuleName BackupCommon Invoke-RestMethod { }

        Send-TelegramAlert -Config $config -Message (('- FireBird/db: failed' + "`n") * 1000) -StorePath $store

        Should -Invoke -ModuleName BackupCommon Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Body.text.Length -le 4096 -and $Body.text -match 'truncated' -and $Body.text.StartsWith('[')
        }
    }
}

Describe 'Config: Encryption and Offsite' {
    It 'requires the passphrase credential and a sane iteration count' {
        $c = Get-ExampleConfig
        $c.Encryption.CredentialName = ''
        $c.Encryption.Iterations = 10
        $problems = @(Test-BackupConfig -Config $c)
        $problems | Should -Contain 'Encryption.CredentialName is required'
        ($problems -join "`n") | Should -Match 'Encryption.Iterations'
    }

    It 'rejects an offsite path inside a local backup folder' {
        $c = Get-ExampleConfig
        $c.Offsite.Path = 'D:\Backup\FireBird\offsite'
        ($(Test-BackupConfig -Config $c) -join "`n") | Should -Match 'must not overlap'
    }

    It 'requires Offsite.Path when enabled' {
        $c = Get-ExampleConfig
        $c.Offsite.Path = ''
        @(Test-BackupConfig -Config $c) | Should -Contain 'Offsite.Path is required'
    }
}
