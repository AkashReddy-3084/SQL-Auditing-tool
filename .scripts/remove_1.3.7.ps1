# Move the long 1.3.7 script into removed_unwanted_20260729222735
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repo = Resolve-Path (Join-Path $scriptDir '..') | Select-Object -ExpandProperty Path
$checks = Join-Path $repo 'SQL\scripts\checks'
$pattern = '*1.3.7*'
$found = Get-ChildItem -Path $checks -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $found) { Write-Output "No file matching $pattern found under $checks"; exit 0 }
$backupDir = Get-ChildItem -Path $checks -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'removed_unwanted_*' } | Sort-Object Name -Descending | Select-Object -First 1
if ($backupDir) { $backup = $backupDir.FullName } else { $backup = Join-Path $checks 'removed_unwanted'; if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null } }
$dest = Join-Path $backup $found.Name
try { Move-Item -Path $found.FullName -Destination $dest -Force; Write-Output "Moved: $($found.FullName) -> $dest" }
catch { Write-Output "Move failed: $($_.Exception.Message)"; exit 1 }

