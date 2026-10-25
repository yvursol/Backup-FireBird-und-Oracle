@{
    Severity = @('Error', 'Warning', 'Information')
    Rules    = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
