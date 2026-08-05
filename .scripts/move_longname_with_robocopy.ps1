$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repo = Resolve-Path (Join-Path $scriptDir '..') | Select-Object -ExpandProperty Path
$checks = Join-Path $repo 'SQL\scripts\checks'
$found = Get-ChildItem -Path $checks -Recurse -Filter '*1.3.7*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $found) { Write-Output "No file matching '*1.3.7*' found under $checks"; exit 0 }
$backupDir = Get-ChildItem -Path $checks -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'removed_unwanted_*' } | Sort-Object Name -Descending | Select-Object -First 1
if ($backupDir) { $backup = $backupDir.FullName } else { $backup = Join-Path $checks 'removed_unwanted'; if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null } }
$srcDir = $found.DirectoryName
$fileName = $found.Name
Write-Output "Robocopy from '$srcDir' to '$backup' file '$fileName'"
$rc = & robocopy $srcDir $backup $fileName /MOV /R:3 /W:1
# robocopy exit codes <8 are success
if ($LASTEXITCODE -lt 8) { Write-Output "Robocopy moved file; exitcode=$LASTEXITCODE" } else { Write-Output "Robocopy failed; exitcode=$LASTEXITCODE" }

