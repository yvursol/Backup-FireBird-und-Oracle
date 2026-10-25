# Stand-in for expdp used by the tests.
#   FAKE_EXPDP_EXIT     = exit code to return (default 0); 1 creates no dump
#   FAKE_DUMP_DIR       = folder that plays the DIRECTORY object
#   FAKE_EXPDP_CAPTURE  = file that receives the parfile content and the arguments
$parFile = $args[0] -replace '^parfile=', ''
$content = @(Get-Content -Path $parFile)

if ($env:FAKE_EXPDP_CAPTURE) {
    Set-Content -Path $env:FAKE_EXPDP_CAPTURE -Value ($content + "ARGS: $($args -join ' ')" + "PARFILE: $parFile")
}

$dump = ($content | Where-Object { $_ -like 'dumpfile=*' }) -replace '^dumpfile=', ''
$log  = ($content | Where-Object { $_ -like 'logfile=*' })  -replace '^logfile=', ''
$code = if ($env:FAKE_EXPDP_EXIT) { [int]$env:FAKE_EXPDP_EXIT } else { 0 }

Set-Content -Path (Join-Path $env:FAKE_DUMP_DIR $log) -Value 'Export: Release 19.0.0.0'
if ($code -ne 1) { Set-Content -Path (Join-Path $env:FAKE_DUMP_DIR $dump) -Value 'fake dump' }
exit $code
