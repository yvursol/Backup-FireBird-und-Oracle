# Stand-in for impdp (SQLFILE check) used by the tests.
#   FAKE_IMPDP_EXIT     = exit code to return (default 0)
#   FAKE_DUMP_DIR       = folder that plays the DIRECTORY object
#   FAKE_IMPDP_CAPTURE  = file that receives the parfile content
$parFile = $args[0] -replace '^parfile=', ''
$content = @(Get-Content -Path $parFile)
if ($env:FAKE_IMPDP_CAPTURE) { Set-Content -Path $env:FAKE_IMPDP_CAPTURE -Value $content }

$dump = ($content | Where-Object { $_ -like 'dumpfile=*' }) -replace '^dumpfile=', ''
$sql  = ($content | Where-Object { $_ -like 'sqlfile=*' })  -replace '^sqlfile=', ''
$log  = ($content | Where-Object { $_ -like 'logfile=*' })  -replace '^logfile=', ''
$code = if ($env:FAKE_IMPDP_EXIT) { [int]$env:FAKE_IMPDP_EXIT } else { 0 }

Set-Content -Path (Join-Path $env:FAKE_DUMP_DIR $log) -Value 'Import: Release 19.0.0.0'
if (-not (Test-Path (Join-Path $env:FAKE_DUMP_DIR $dump))) { exit 1 }
if ($code -eq 0) { Set-Content -Path (Join-Path $env:FAKE_DUMP_DIR $sql) -Value '-- CREATE TABLE ...' }
exit $code
