#Requires -Version 5.1
# Shared helpers for the backup scripts: config, logging, credentials, encryption,
# checksums, retention, offsite copies, freshness checks and alerting.

Set-StrictMode -Version Latest
# Module functions do not see the caller's $ErrorActionPreference (a module has its own
# scope chain that ends in the global scope). Make every error inside the module
# terminating, so a failed Move-Item or Remove-Item can never be silently skipped.
$ErrorActionPreference = 'Stop'

$script:LogFile         = $null
$script:EventSource     = 'BackupAutomation'
$script:TimestampRegex  = '\d{8}_\d{6}'
$script:DirManifestName = 'SHA256SUMS'
$script:OffsiteDrive    = 'BackupOffsite'
# Limits of the alert channels. Telegram rejects messages over 4096 characters,
# an event log entry may hold at most 31839.
$script:TelegramMaxLength = 4000
$script:EventLogMaxLength = 31000

# PowerShell 5.1 on Server 2016 still defaults to TLS 1.0, which api.telegram.org rejects.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Encryption and free-space helpers (C#), see lib/BackupNative.cs.
if (-not ('BackupAutomation.FileCrypto' -as [type])) {
    $nativeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'BackupNative.cs') -Raw
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # .NET Framework: System.Security.Cryptography.Aes lives in System.Core
        Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies 'System.Core'
    }
    else {
        Add-Type -TypeDefinition $nativeSource
    }
}

function Test-IsWindows {
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Resolve-FullPath {
    <#
    .SYNOPSIS
        Absolute file system path for a PowerShell path (also for paths that do not exist yet).
        .NET methods resolve relative paths against the process directory, not $PWD.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-InnermostMessage {
    param([Parameter(Mandatory)][System.Exception]$Exception)
    while ($null -ne $Exception.InnerException) { $Exception = $Exception.InnerException }
    $Exception.Message
}

#region Config

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Reads an optional property from a config object (StrictMode-safe).
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Test-ComponentEnabled {
    <#
    .SYNOPSIS
        True if the config section (VMware, FireBird, Oracle, Telegram) exists and has Enabled = true.
    #>
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][string]$Name)
    $section = Get-ConfigValue -Object $Config -Name $Name
    return [bool](Get-ConfigValue -Object $section -Name 'Enabled' -Default $false)
}

function Test-BackupConfig {
    <#
    .SYNOPSIS
        Validates a parsed config object. Returns a list of problems (empty = valid).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Config)

    $errors = New-Object System.Collections.Generic.List[string]

    # Returns the value and records an error if it is missing or blank.
    function Get-RequiredValue([object]$Obj, [string]$Name, [string]$Where) {
        $value = Get-ConfigValue -Object $Obj -Name $Name
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            $errors.Add("$Where.$Name is required")
        }
        return $value
    }

    $minFree = Get-ConfigValue -Object $Config -Name 'MinFreeSpaceGB'
    if ($null -eq $minFree -or $minFree -lt 0) { $errors.Add('MinFreeSpaceGB must be a number >= 0') }

    $retention = Get-ConfigValue -Object $Config -Name 'Retention'
    $days    = Get-ConfigValue -Object $retention -Name 'Days'
    $minKeep = Get-ConfigValue -Object $retention -Name 'MinKeep'
    if ($null -eq $days -or $days -lt 0)       { $errors.Add('Retention.Days must be an integer >= 0 (0 disables retention)') }
    if ($null -eq $minKeep -or $minKeep -lt 1) { $errors.Add('Retention.MinKeep must be an integer >= 1') }

    $maxAge = Get-ConfigValue -Object (Get-ConfigValue -Object $Config -Name 'Monitoring') -Name 'MaxBackupAgeHours'
    if ($null -eq $maxAge -or $maxAge -le 0) { $errors.Add('Monitoring.MaxBackupAgeHours must be > 0') }

    $anyEnabled = $false

    if (Test-ComponentEnabled -Config $Config -Name 'VMware') {
        $anyEnabled = $true
        $vmw = $Config.VMware
        $null = Get-RequiredValue -Obj $vmw -Name 'VCenter' -Where 'VMware'
        $null = Get-RequiredValue -Obj $vmw -Name 'CredentialName' -Where 'VMware'
        $null = Get-RequiredValue -Obj $vmw -Name 'BackupPath' -Where 'VMware'
        if (@(Get-ConfigValue -Object $vmw -Name 'VirtualMachines' -Default @()).Count -eq 0) {
            $errors.Add('VMware.VirtualMachines must contain at least one VM')
        }
    }

    if (Test-ComponentEnabled -Config $Config -Name 'FireBird') {
        $anyEnabled = $true
        $fb = $Config.FireBird
        $null = Get-RequiredValue -Obj $fb -Name 'GbakPath' -Where 'FireBird'
        $null = Get-RequiredValue -Obj $fb -Name 'BackupPath' -Where 'FireBird'
        $dbs = @(Get-ConfigValue -Object $fb -Name 'Databases' -Default @())
        if ($dbs.Count -eq 0) { $errors.Add('FireBird.Databases must contain at least one database') }
        $seen = @{}
        for ($i = 0; $i -lt $dbs.Count; $i++) {
            $where = "FireBird.Databases[$i]"
            $name = Get-RequiredValue -Obj $dbs[$i] -Name 'Name' -Where $where
            $null = Get-RequiredValue -Obj $dbs[$i] -Name 'Path' -Where $where
            $null = Get-RequiredValue -Obj $dbs[$i] -Name 'CredentialName' -Where $where
            if ($name) {
                if ($name -notmatch '^[A-Za-z0-9_-]+$') { $errors.Add("$where.Name '$name' may only contain letters, digits, '_' and '-'") }
                if ($seen.ContainsKey($name)) { $errors.Add("$where.Name '$name' is used more than once") }
                $seen[$name] = $true
            }
        }
    }

    if (Test-ComponentEnabled -Config $Config -Name 'Oracle') {
        $anyEnabled = $true
        $ora = $Config.Oracle
        $null = Get-RequiredValue -Obj $ora -Name 'TnsName' -Where 'Oracle'
        $null = Get-RequiredValue -Obj $ora -Name 'DirectoryObject' -Where 'Oracle'
        $null = Get-RequiredValue -Obj $ora -Name 'DumpDirectoryPath' -Where 'Oracle'
        $null = Get-RequiredValue -Obj $ora -Name 'BackupPath' -Where 'Oracle'
        $label = Get-RequiredValue -Obj $ora -Name 'Label' -Where 'Oracle'
        if ($label -and $label -notmatch '^[A-Za-z0-9_-]+$') { $errors.Add("Oracle.Label '$label' may only contain letters, digits, '_' and '-'") }
        if (-not (Get-ConfigValue -Object $ora -Name 'UseWallet' -Default $false)) { $null = Get-RequiredValue -Obj $ora -Name 'CredentialName' -Where 'Oracle' }
        $compression = Get-ConfigValue -Object $ora -Name 'Compression' -Default 'METADATA_ONLY'
        if ($compression -notin 'ALL', 'DATA_ONLY', 'METADATA_ONLY', 'NONE') {
            $errors.Add("Oracle.Compression '$compression' must be one of ALL, DATA_ONLY, METADATA_ONLY, NONE")
        }
    }

    if (-not $anyEnabled) { $errors.Add('Nothing to do: enable at least one of VMware, FireBird, Oracle') }

    if (Test-ComponentEnabled -Config $Config -Name 'Encryption') {
        $null = Get-RequiredValue -Obj $Config.Encryption -Name 'CredentialName' -Where 'Encryption'
        $iterations = Get-ConfigValue -Object $Config.Encryption -Name 'Iterations' -Default ([BackupAutomation.FileCrypto]::DefaultIterations)
        if ($iterations -lt 100000 -or $iterations -gt [BackupAutomation.FileCrypto]::MaxIterations) {
            $errors.Add("Encryption.Iterations must be between 100000 and $([BackupAutomation.FileCrypto]::MaxIterations)")
        }
    }

    if (Test-ComponentEnabled -Config $Config -Name 'Offsite') {
        $off = $Config.Offsite
        $offPath = Get-RequiredValue -Obj $off -Name 'Path' -Where 'Offsite'
        if ($offPath) {
            $localPaths = @(foreach ($name in 'VMware', 'FireBird', 'Oracle') {
                if (Test-ComponentEnabled -Config $Config -Name $name) { $Config.$name.BackupPath }
            })
            foreach ($local in $localPaths) {
                $a = $offPath.TrimEnd('\', '/')
                $b = "$local".TrimEnd('\', '/')
                if ($a -eq $b -or $a.StartsWith("$b\") -or $a.StartsWith("$b/") -or $b.StartsWith("$a\") -or $b.StartsWith("$a/")) {
                    $errors.Add("Offsite.Path '$offPath' must not overlap with the local BackupPath '$local'")
                }
            }
        }
        $offRetention = Get-ConfigValue -Object $off -Name 'Retention'
        if ($null -ne $offRetention) {
            $offDays = Get-ConfigValue -Object $offRetention -Name 'Days'
            $offKeep = Get-ConfigValue -Object $offRetention -Name 'MinKeep'
            if ($null -ne $offDays -and $offDays -lt 0) { $errors.Add('Offsite.Retention.Days must be an integer >= 0') }
            if ($null -ne $offKeep -and $offKeep -lt 1) { $errors.Add('Offsite.Retention.MinKeep must be an integer >= 1') }
        }
        $offFree = Get-ConfigValue -Object $off -Name 'MinFreeSpaceGB' -Default 0
        if ($offFree -lt 0) { $errors.Add('Offsite.MinFreeSpaceGB must be a number >= 0') }
    }

    if (Test-ComponentEnabled -Config $Config -Name 'Telegram') {
        $null = Get-RequiredValue -Obj $Config.Telegram -Name 'CredentialName' -Where 'Telegram'
        $null = Get-RequiredValue -Obj $Config.Telegram -Name 'ChatId' -Where 'Telegram'
    }

    return $errors.ToArray()
}

function Get-BackupConfig {
    <#
    .SYNOPSIS
        Loads and validates config.json. Throws with every problem listed if invalid.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path (copy config.example.json to config.json and edit it)"
    }
    try {
        $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Config file $Path is not valid JSON: $($_.Exception.Message)"
    }
    $problems = @(Test-BackupConfig -Config $config)
    if ($problems.Count -gt 0) {
        throw "Invalid config ${Path}:`n  - " + ($problems -join "`n  - ")
    }
    return $config
}

#endregion

#region Logging

function Initialize-BackupLog {
    <#
    .SYNOPSIS
        Sets the daily log file (<Directory>/<Name>_yyyyMMdd.log) used by Write-BackupLog.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $script:LogFile = Join-Path $Directory ("{0}_{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd'))
    return $script:LogFile
}

function Write-BackupLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the log file and the information stream.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    Write-Information $line -InformationAction Continue
}

function Write-BackupEvent {
    <#
    .SYNOPSIS
        Writes a summary event to the Windows Application log (source BackupAutomation),
        so the result can be picked up by Zabbix/SCOM. Skipped when the source is not
        registered (setup.ps1 registers it) or when not running on Windows.
    .NOTES
        Uses System.Diagnostics.EventLog directly instead of Write-EventLog, which does
        not exist in PowerShell 7. Works the same in Windows PowerShell 5.1 and PowerShell 7.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information',
        [int]$EventId = 1000
    )
    if (-not (Test-IsWindows)) { return }
    try {
        if (-not ('System.Diagnostics.EventLog' -as [type])) {
            Add-Type -AssemblyName 'System.Diagnostics.EventLog'
        }
        if ([System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            [System.Diagnostics.EventLog]::WriteEntry($script:EventSource,
                (Format-AlertText -Text $Message -MaxLength $script:EventLogMaxLength),
                [System.Diagnostics.EventLogEntryType]$EntryType, $EventId)
        }
    }
    catch {
        Write-BackupLog "Could not write to the event log: $($_.Exception.Message)" -Level WARN
    }
}

function Remove-OldLog {
    <#
    .SYNOPSIS
        Deletes *.log files older than -Days from the log directory (0 = keep forever).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][int]$Days)
    if ($Days -le 0 -or -not (Test-Path -LiteralPath $Directory)) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove old log')) { Remove-Item -LiteralPath $_.FullName -Force }
        }
}

#endregion

#region Credentials

function Get-BackupCredential {
    <#
    .SYNOPSIS
        Loads a DPAPI-encrypted PSCredential from the credential store.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$StorePath
    )
    $path = Join-Path $StorePath "$Name.cred.xml"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Credential '$Name' not found at $path. Run Set-BackupCredentials.ps1 as the account that runs the backup."
    }
    $cred = Import-Clixml -LiteralPath $path
    if ($cred -isnot [System.Management.Automation.PSCredential]) {
        throw "File $path does not contain a PSCredential"
    }
    return $cred
}

function Set-BackupCredential {
    <#
    .SYNOPSIS
        Stores a PSCredential DPAPI-encrypted in the credential store and restricts its ACL.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$StorePath
    )
    if (-not (Test-Path -LiteralPath $StorePath)) {
        New-Item -ItemType Directory -Path $StorePath -Force | Out-Null
        Protect-File -Path $StorePath
    }
    $path = Join-Path $StorePath "$Name.cred.xml"
    if ($PSCmdlet.ShouldProcess($path, 'Store encrypted credential')) {
        # Export-Clixml encrypts the SecureString with DPAPI (current user + machine).
        $Credential | Export-Clixml -LiteralPath $path
        Protect-File -Path $path
    }
    return $path
}

function Protect-File {
    <#
    .SYNOPSIS
        Restricts a file or folder ACL to the current account only (no inheritance).
        No-op outside Windows.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsWindows)) { return }

    $item = Get-Item -LiteralPath $Path -Force
    $sid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($item.PSIsContainer) {
        $acl  = New-Object System.Security.AccessControl.DirectorySecurity
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    }
    else {
        $acl  = New-Object System.Security.AccessControl.FileSecurity
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

#endregion

#region Backup sets, retention, freshness

function Get-BackupSet {
    <#
    .SYNOPSIS
        Groups backup artifacts by the timestamp in their name, newest first.
    .DESCRIPTION
        Only names created by these scripts are considered:
          files:       <Prefix>_yyyyMMdd_HHmmss.<ext>[.<ext>]   e.g. court_db_20261025_020000.fbk
          directories: yyyyMMdd_HHmmss                          (VM exports)
        Anything else (including in-progress names starting with '.') is ignored,
        so retention never touches files it did not create.
        Ordering uses the timestamp in the name, not LastWriteTime: deleting files
        inside a directory changes its LastWriteTime on NTFS.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Prefix = '',
        [switch]$Directory
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $pattern = if ($Directory) { "^($script:TimestampRegex)$" }
               else { '^' + [regex]::Escape($Prefix) + "_($script:TimestampRegex)(\.[^.]+)+$" }

    $items = Get-ChildItem -LiteralPath $Path -Force |
        Where-Object { [bool]$_.PSIsContainer -eq [bool]$Directory -and $_.Name -match $pattern } |
        ForEach-Object {
            [pscustomobject]@{
                Timestamp = [datetime]::ParseExact($Matches[1], 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture)
                Item      = $_
            }
        }

    @($items | Group-Object Timestamp | ForEach-Object {
        [pscustomobject]@{
            Timestamp = $_.Group[0].Timestamp
            Items     = @($_.Group | ForEach-Object { $_.Item })
        }
    } | Sort-Object Timestamp -Descending)
}

function Remove-ExpiredBackup {
    <#
    .SYNOPSIS
        Deletes backup sets older than RetentionDays, but always keeps the newest MinKeep sets
        regardless of age - so a run of failed backups can never wipe the last good copies.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Prefix = '',
        [Parameter(Mandatory)][int]$RetentionDays,
        [ValidateRange(1, [int]::MaxValue)][int]$MinKeep = 1,
        [switch]$Directory
    )
    if ($RetentionDays -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)

    Get-BackupSet -Path $Path -Prefix $Prefix -Directory:$Directory |
        Select-Object -Skip $MinKeep |
        Where-Object { $_.Timestamp -lt $cutoff } |
        ForEach-Object {
            foreach ($item in $_.Items) {
                if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove expired backup')) {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force
                    $item.FullName
                }
            }
        }
}

function Test-BackupFreshness {
    <#
    .SYNOPSIS
        Checks the newest backup set. Returns $null if OK, otherwise a problem description.
    .PARAMETER RequiredPattern
        Wildcards; at least one non-empty file in the newest set must match one of them
        (searched recursively for directory sets). Pass the encrypted variant as well,
        e.g. '*.fbk', '*.fbk.enc'.
    .PARAMETER VerifyChecksums
        Also require a SHA256 manifest in the newest set and re-hash every file it lists.
        Reads the whole backup.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Prefix = '',
        [switch]$Directory,
        [Parameter(Mandatory)][double]$MaxAgeHours,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$RequiredPattern,
        [switch]$VerifyChecksums
    )
    if (-not (Test-Path -LiteralPath $Path)) { return "${Label}: backup directory does not exist: $Path" }

    $latest = Get-BackupSet -Path $Path -Prefix $Prefix -Directory:$Directory | Select-Object -First 1
    if (-not $latest) { return "${Label}: no backups found in $Path" }

    $age = (Get-Date) - $latest.Timestamp
    if ($age.TotalHours -gt $MaxAgeHours) {
        return ('{0}: newest backup is {1:N1}h old (limit {2}h)' -f $Label, $age.TotalHours, $MaxAgeHours)
    }

    $candidates = if ($Directory) { Get-ChildItem -LiteralPath $latest.Items[0].FullName -File -Recurse } else { $latest.Items }
    $files = @($candidates | Where-Object {
        $name = $_.Name
        @($RequiredPattern | Where-Object { $name -like $_ }).Count -gt 0
    })
    if ($files.Count -eq 0) { return "${Label}: newest backup has no $($RequiredPattern -join ' / ') file" }
    $empty = @($files | Where-Object { $_.Length -eq 0 })
    if ($empty.Count -gt 0) { return "${Label}: empty file in newest backup: $($empty[0].FullName)" }

    if ($VerifyChecksums) {
        $manifest = Get-BackupSetManifest -Set $latest -Directory:$Directory
        if (-not $manifest) { return "${Label}: newest backup has no SHA256 manifest" }
        $problems = @(Test-BackupManifest -Path $manifest)
        if ($problems.Count -gt 0) {
            $more = if ($problems.Count -gt 1) { " (+$($problems.Count - 1) more)" } else { '' }
            return "${Label}: checksum verification failed: $($problems[0])$more"
        }
    }

    return $null
}

function Get-FreeSpaceGB {
    <#
    .SYNOPSIS
        Free space in GB on the volume that holds -Path. -Path may be a UNC path and does
        not have to exist yet (the nearest existing parent folder is used).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $probe = Resolve-FullPath $Path
    while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
        $probe = Split-Path -Path $probe -Parent
    }
    if (-not $probe) { throw "Cannot determine free space for ${Path}: no existing parent folder" }

    $bytes = if (Test-IsWindows) {
        [BackupAutomation.NativeDisk]::GetAvailableBytes($probe)
    }
    else {
        (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($probe))).AvailableFreeSpace
    }
    return [math]::Round($bytes / 1GB, 2)
}

function Assert-FreeSpace {
    <#
    .SYNOPSIS
        Throws unless the volume of -Path has RequiredGB + ReserveGB free.
        Called before every step that writes a lot of data, not only once per run.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$RequiredGB = 0,
        [double]$ReserveGB = 0,
        [string]$Purpose = 'backup'
    )
    $free = Get-FreeSpaceGB -Path $Path
    $need = [math]::Round($RequiredGB + $ReserveGB, 2)
    if ($free -lt $need) {
        throw ('Not enough free space for {0} on {1}: {2}GB free, need ~{3}GB ({4:N2}GB + {5}GB reserve)' -f
            $Purpose, $Path, $free, $need, $RequiredGB, $ReserveGB)
    }
}

function Get-ItemSizeGB {
    param([Parameter(Mandatory)][string[]]$Path)
    $bytes = 0
    foreach ($p in $Path) {
        $item = Get-Item -LiteralPath $p -Force
        if ($item.PSIsContainer) {
            $sum = (Get-ChildItem -LiteralPath $p -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $bytes += $sum }
        }
        else { $bytes += $item.Length }
    }
    return $bytes / 1GB
}

#endregion

#region Encryption and checksums

function Protect-BackupFile {
    <#
    .SYNOPSIS
        Encrypts a file with AES-256-CBC + HMAC-SHA256; the key is derived from the
        credential's password (the passphrase) with PBKDF2-SHA256. Format: lib/BackupNative.cs.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [ValidateRange(1000, 10000000)][int]$Iterations = 600000
    )
    $source = Resolve-FullPath $Path
    $target = Resolve-FullPath $Destination
    if (Test-Path -LiteralPath $target) { throw "Encryption target already exists: $target" }
    try {
        [BackupAutomation.FileCrypto]::EncryptFile($source, $target, $Credential.GetNetworkCredential().Password, $Iterations)
    }
    catch {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw "Encryption of $source failed: $(Get-InnermostMessage $_.Exception)"
    }
}

function Unprotect-BackupFile {
    <#
    .SYNOPSIS
        Decrypts a file created by Protect-BackupFile. The plaintext is only kept if the
        integrity check (HMAC) over the whole file succeeded. Without -Destination the
        file is only verified.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Destination,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )
    $source = Resolve-FullPath $Path
    $passphrase = $Credential.GetNetworkCredential().Password
    if (-not $Destination) {
        try { [BackupAutomation.FileCrypto]::VerifyFile($source, $passphrase) }
        catch { throw "Verification of $source failed: $(Get-InnermostMessage $_.Exception)" }
        return
    }
    $target = Resolve-FullPath $Destination
    if (Test-Path -LiteralPath $target) { throw "Decryption target already exists: $target" }
    try {
        [BackupAutomation.FileCrypto]::DecryptFile($source, $target, $passphrase)
    }
    catch {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw "Decryption of $source failed: $(Get-InnermostMessage $_.Exception)"
    }
}

function Write-BackupManifest {
    <#
    .SYNOPSIS
        Writes a SHA256 manifest in sha256sum format ("<hash>  <name>", LF, UTF-8 without BOM),
        so it can also be checked with `sha256sum -c` on Linux.
    .PARAMETER Entry
        Objects with Name (path relative to the manifest folder, '/' separated, as it will be
        called once the set is complete) and Path (where the file is right now).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Entry
    )
    $lines = foreach ($e in $Entry) {
        $hash = (Get-FileHash -LiteralPath $e.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $($e.Name)"
    }
    $text = (@($lines) -join "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-FullPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-BackupManifest {
    <#
    .SYNOPSIS
        Re-hashes every file listed in a manifest. Returns a list of problems (empty = OK).
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @("manifest not found: $Path") }
    $base  = Split-Path -Path (Resolve-FullPath $Path) -Parent
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return @("manifest is empty: $Path") }

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') {
            $problems.Add("malformed manifest line: $line")
            continue
        }
        $expected = $Matches[1].ToLowerInvariant()
        $name     = $Matches[2]
        if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
            $problems.Add("unsafe path in manifest: $name")
            continue
        }
        $file = Join-Path $base ($name -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $problems.Add("${name}: missing")
            continue
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { $problems.Add("${name}: SHA256 mismatch") }
    }
    return $problems.ToArray()
}

function Get-BackupSetManifest {
    <#
    .SYNOPSIS
        Path of the manifest of a backup set from Get-BackupSet, or $null if it has none.
    #>
    param([Parameter(Mandatory)][object]$Set, [switch]$Directory)
    if ($Directory) {
        $path = Join-Path $Set.Items[0].FullName $script:DirManifestName
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        return $null
    }
    $item = $Set.Items | Where-Object { $_.Name -like '*.sha256' } | Select-Object -First 1
    if ($item) { return $item.FullName }
    return $null
}

function Complete-BackupFileSet {
    <#
    .SYNOPSIS
        Turns the files of one finished backup into a complete set in -Directory:
        optional encryption, SHA256 manifest <BaseName>.sha256, rename to the final names.
    .DESCRIPTION
        Everything is first written under temporary names (leading '.'); the final names
        appear only at the end and the manifest is renamed last. A set without manifest is
        therefore incomplete, and check-backup.ps1 reports it.
        Sources of encrypted files are deleted only after the set is complete. Unencrypted
        sources are moved into the set.
    .PARAMETER File
        Objects with Source (current path), Name (final name without .enc) and Encrypt (bool).
    .OUTPUTS
        PSCustomObject with Files (final paths) and Manifest.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][object[]]$File,
        [System.Management.Automation.PSCredential]$EncryptionCredential,
        [int]$Iterations = 600000,
        [double]$ReserveGB = 0
    )
    $Directory = Resolve-FullPath $Directory
    $staged = New-Object System.Collections.Generic.List[object]
    $manifestPartial = Join-Path $Directory ".$BaseName.sha256"
    $manifestFinal   = Join-Path $Directory "$BaseName.sha256"
    $complete = $false
    try {
        foreach ($f in $File) {
            $source    = Resolve-FullPath $f.Source
            $encrypt   = [bool]$f.Encrypt -and $null -ne $EncryptionCredential
            $finalName = if ($encrypt) { "$($f.Name).enc" } else { $f.Name }
            $partial   = Join-Path $Directory ".$finalName"
            if ($encrypt) {
                Assert-FreeSpace -Path $Directory -RequiredGB (Get-ItemSizeGB $source) -ReserveGB $ReserveGB -Purpose "encrypting $($f.Name)"
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                Protect-BackupFile -Path $source -Destination $partial -Credential $EncryptionCredential -Iterations $Iterations
            }
            elseif ($source -ne $partial) {
                if ((Split-Path -Path $source -Parent) -ne $Directory) {
                    Assert-FreeSpace -Path $Directory -RequiredGB (Get-ItemSizeGB $source) -ReserveGB $ReserveGB -Purpose "moving $($f.Name)"
                }
                Move-Item -LiteralPath $source -Destination $partial -Force
            }
            $staged.Add([pscustomobject]@{ Name = $finalName; Partial = $partial; Final = (Join-Path $Directory $finalName) })
        }

        Write-BackupManifest -Path $manifestPartial -Entry @($staged | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.Partial } })
        foreach ($s in $staged) { Move-Item -LiteralPath $s.Partial -Destination $s.Final -Force }
        Move-Item -LiteralPath $manifestPartial -Destination $manifestFinal -Force
        $complete = $true
    }
    finally {
        if (-not $complete) {
            foreach ($s in $staged) { Remove-Item -LiteralPath $s.Partial -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $manifestPartial -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($f in $File) {
        if ([bool]$f.Encrypt -and $null -ne $EncryptionCredential) {
            Remove-Item -LiteralPath $f.Source -Force -ErrorAction SilentlyContinue
        }
    }
    [pscustomobject]@{
        Files    = @($staged | ForEach-Object { $_.Final })
        Manifest = $manifestFinal
    }
}

function Complete-BackupDirectory {
    <#
    .SYNOPSIS
        Encrypts (optional) every file of a backup folder in place and writes SHA256SUMS.
        Used for VM exports while the folder still has its temporary name.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Management.Automation.PSCredential]$EncryptionCredential,
        [int]$Iterations = 600000,
        [double]$ReserveGB = 0
    )
    $base  = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $base -File -Recurse -Force | Where-Object { $_.Name -ne $script:DirManifestName })
    if ($null -ne $EncryptionCredential) {
        $files = @(foreach ($f in $files) {
            Assert-FreeSpace -Path $base -RequiredGB ($f.Length / 1GB) -ReserveGB $ReserveGB -Purpose "encrypting $($f.Name)"
            $encrypted = "$($f.FullName).enc"
            Protect-BackupFile -Path $f.FullName -Destination $encrypted -Credential $EncryptionCredential -Iterations $Iterations
            Remove-Item -LiteralPath $f.FullName -Force
            Get-Item -LiteralPath $encrypted -Force
        })
    }
    $entries = @($files | ForEach-Object {
        [pscustomobject]@{
            Name = $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
            Path = $_.FullName
        }
    })
    Write-BackupManifest -Path (Join-Path $base $script:DirManifestName) -Entry $entries
}

#endregion

#region Offsite copies

function Get-OffsitePath {
    <#
    .SYNOPSIS
        Offsite folder of a target: <Offsite.Path>\VMware\<VM>, \FireBird, \Oracle.
    #>
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][ValidateSet('VMware', 'FireBird', 'Oracle')][string]$Component,
        [string]$Target = ''
    )
    $path = Join-Path $Config.Offsite.Path $Component
    if ($Component -eq 'VMware') { $path = Join-Path $path $Target }
    return $path
}

function Connect-OffsiteStore {
    <#
    .SYNOPSIS
        Makes Offsite.Path reachable. Without Offsite.CredentialName the account running the
        task (SYSTEM = the computer account DOMAIN\HOST$) needs write access on the share.
        With CredentialName an SMB connection with that credential is made for this process.
    #>
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$StorePath
    )
    $off = $Config.Offsite
    $credName = Get-ConfigValue -Object $off -Name 'CredentialName'
    if ($credName) {
        $cred = Get-BackupCredential -Name $credName -StorePath $StorePath
        Remove-PSDrive -Name $script:OffsiteDrive -Scope Global -Force -ErrorAction SilentlyContinue
        New-PSDrive -Name $script:OffsiteDrive -PSProvider FileSystem -Root $off.Path -Credential $cred -Scope Global -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $off.Path -PathType Container)) {
        # First run: the share exists, the per-server folder below it does not yet.
        try { New-Item -ItemType Directory -Path $off.Path -Force | Out-Null }
        catch { throw "Offsite.Path '$($off.Path)' is not reachable: $(Get-InnermostMessage $_.Exception)" }
        if (-not (Test-Path -LiteralPath $off.Path -PathType Container)) {
            throw "Offsite.Path '$($off.Path)' is not reachable"
        }
    }
}

function Disconnect-OffsiteStore {
    Remove-PSDrive -Name $script:OffsiteDrive -Scope Global -Force -ErrorAction SilentlyContinue
}

function Copy-BackupSetToOffsite {
    <#
    .SYNOPSIS
        Copies backup sets that the offsite folder does not have yet and verifies them there.
    .DESCRIPTION
        Copies every local set newer than the newest offsite set (all missed nights after an
        outage); if the offsite folder is empty, only the newest local set. Each set is copied
        into a temporary folder on the destination, its SHA256 manifest is verified THERE,
        and only then it is moved to its final name. Sets without manifest are refused.
    .OUTPUTS
        PSCustomObject with Copied (number of sets), SizeGB and Destination.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Prefix = '',
        [switch]$Directory,
        [Parameter(Mandatory)][string]$Destination,
        [double]$MinFreeSpaceGB = 0
    )
    $local = @(Get-BackupSet -Path $Path -Prefix $Prefix -Directory:$Directory)
    if ($local.Count -eq 0) { throw "No local backup set in $Path to copy" }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    # Leftovers of an interrupted copy (temporary names are never counted as backups)
    $stalePattern = if ($Directory) { "^\.$script:TimestampRegex$" } else { '^\.incoming_' + [regex]::Escape($Prefix) + "_$script:TimestampRegex$" }
    Get-ChildItem -LiteralPath $Destination -Directory -Force |
        Where-Object { $_.Name -match $stalePattern } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

    $remoteNewest = Get-BackupSet -Path $Destination -Prefix $Prefix -Directory:$Directory | Select-Object -First 1
    $toCopy = if ($remoteNewest) { @($local | Where-Object { $_.Timestamp -gt $remoteNewest.Timestamp }) } else { @($local[0]) }

    $copiedGB = 0
    foreach ($set in @($toCopy | Sort-Object Timestamp)) {
        $stamp   = $set.Timestamp.ToString('yyyyMMdd_HHmmss')
        $manifest = Get-BackupSetManifest -Set $set -Directory:$Directory
        if (-not $manifest) { throw "Backup set $stamp in $Path has no SHA256 manifest; refusing to copy it unverified" }

        $sizeGB = Get-ItemSizeGB @($set.Items | ForEach-Object { $_.FullName })
        Assert-FreeSpace -Path $Destination -RequiredGB $sizeGB -ReserveGB $MinFreeSpaceGB -Purpose "offsite copy of $stamp"

        $staging = if ($Directory) { Join-Path $Destination ".$stamp" } else { Join-Path $Destination ".incoming_${Prefix}_$stamp" }
        $done = $false
        try {
            if ($Directory) {
                Copy-Item -LiteralPath $set.Items[0].FullName -Destination $staging -Recurse -Force
                $stagedManifest = Join-Path $staging $script:DirManifestName
            }
            else {
                New-Item -ItemType Directory -Path $staging -Force | Out-Null
                foreach ($item in $set.Items) { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $staging $item.Name) -Force }
                $stagedManifest = Join-Path $staging (Split-Path -Path $manifest -Leaf)
            }

            $problems = @(Test-BackupManifest -Path $stagedManifest)
            if ($problems.Count -gt 0) { throw "Offsite copy of $stamp failed verification: $($problems -join '; ')" }

            if ($Directory) {
                Move-Item -LiteralPath $staging -Destination (Join-Path $Destination $stamp)
            }
            else {
                # manifest last: a set without manifest is incomplete
                $files = @(Get-ChildItem -LiteralPath $staging -File -Force | Sort-Object { $_.Name -like '*.sha256' })
                foreach ($f in $files) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $Destination $f.Name) -Force }
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
            $done = $true
        }
        finally {
            if (-not $done) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $copiedGB += $sizeGB
    }

    [pscustomobject]@{
        Copied      = @($toCopy).Count
        SizeGB      = [math]::Round($copiedGB, 2)
        Destination = $Destination
    }
}

#endregion

#region Native commands and alerts

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs an external tool and returns its exit code and combined output.
        Avoids Windows PowerShell 5.1 turning stderr lines into terminating errors
        when $ErrorActionPreference is 'Stop'.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Output   = @($output)
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Format-AlertText {
    <#
    .SYNOPSIS
        Shortens a message to -MaxLength characters, saying how much was cut.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateRange(100, [int]::MaxValue)][int]$MaxLength
    )
    if ($Text.Length -le $MaxLength) { return $Text }
    $suffixTemplate = "`n... [truncated, {0} more characters - see the log on the backup server]"
    $cut = $MaxLength - ($suffixTemplate -f $Text.Length).Length
    # never split a UTF-16 surrogate pair
    if ([char]::IsHighSurrogate($Text[$cut - 1])) { $cut-- }
    return $Text.Substring(0, $cut) + ($suffixTemplate -f ($Text.Length - $cut))
}

function Send-TelegramAlert {
    <#
    .SYNOPSIS
        Sends a message to the configured Telegram chat. Never throws; failures are logged.
        Long messages are shortened to the Telegram limit.
    #>
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$StorePath
    )
    if (-not (Test-ComponentEnabled -Config $Config -Name 'Telegram')) { return }
    try {
        $cred  = Get-BackupCredential -Name $Config.Telegram.CredentialName -StorePath $StorePath
        $token = $cred.GetNetworkCredential().Password
        $body  = @{
            chat_id = $Config.Telegram.ChatId
            text    = Format-AlertText -Text "[$([Environment]::MachineName)] $Message" -MaxLength $script:TelegramMaxLength
        }
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body $body -TimeoutSec 30 | Out-Null
    }
    catch {
        # Never let alerting failures mask the original problem.
        Write-BackupLog "Telegram alert failed: $($_.Exception.Message)" -Level WARN
    }
}

#endregion

Export-ModuleMember -Function `
    Get-ConfigValue, Test-ComponentEnabled, Test-BackupConfig, Get-BackupConfig, `
    Initialize-BackupLog, Write-BackupLog, Write-BackupEvent, Remove-OldLog, `
    Get-BackupCredential, Set-BackupCredential, Protect-File, `
    Get-BackupSet, Remove-ExpiredBackup, Test-BackupFreshness, `
    Get-FreeSpaceGB, Assert-FreeSpace, Get-ItemSizeGB, `
    Protect-BackupFile, Unprotect-BackupFile, Write-BackupManifest, Test-BackupManifest, `
    Get-BackupSetManifest, Complete-BackupFileSet, Complete-BackupDirectory, `
    Get-OffsitePath, Connect-OffsiteStore, Disconnect-OffsiteStore, Copy-BackupSetToOffsite, `
    Invoke-NativeCommand, Format-AlertText, Send-TelegramAlert
