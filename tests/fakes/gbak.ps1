# Stand-in for gbak.exe used by the tests.
#   FAKE_GBAK_FAIL   = '-b' or '-c'  -> that step exits with code 1
#   FAKE_GBAK_EMPTY  = '1'           -> backup step creates an empty file
#   FAKE_ARGS_FILE   = path          -> command lines are appended there
$mode   = $args[0]
$target = $args[-1]

if ($env:FAKE_ARGS_FILE) { Add-Content -Path $env:FAKE_ARGS_FILE -Value ($args -join ' ') }

"gbak $($args -join ' ')"
"ISC_USER=$env:ISC_USER"
"ISC_PASSWORD set: $(-not [string]::IsNullOrEmpty($env:ISC_PASSWORD))"

if ($env:FAKE_GBAK_FAIL -eq $mode) {
    'ERROR: simulated failure'
    exit 1
}
if ($mode -eq '-b' -and $env:FAKE_GBAK_EMPTY -eq '1') {
    New-Item -ItemType File -Path $target -Force | Out-Null
    exit 0
}
Set-Content -Path $target -Value "fake $mode output"
exit 0
