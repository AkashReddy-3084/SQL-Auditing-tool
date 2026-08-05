Set-StrictMode -Version Latest
$repo = Split-Path -Parent $MyInvocation.MyCommand.Definition
# repo is .scripts; go up one
$repo = Resolve-Path (Join-Path $repo '..') | Select-Object -ExpandProperty Path
$checks = Join-Path $repo 'SQL\scripts\checks'
$map = Join-Path $repo 'Backend\checklist\deterministic-script-mapping.json'
if (-not (Test-Path $checks)) { Write-Output "Checks folder missing: $checks"; exit 1 }
if (-not (Test-Path $map)) { Write-Output "Mapping file missing: $map"; exit 1 }
$files = Get-ChildItem -Path $checks -Filter '*.sql' -File | Select-Object -ExpandProperty Name
$json = Get-Content $map -Raw | ConvertFrom-Json
$mapped = @()
# ConvertFrom-Json yields a PSCustomObject; enumerate property names to get keys
foreach ($prop in $json.PSObject.Properties) {
    $arr = $json.$($prop.Name)
    foreach ($it in $arr) { $mapped += [System.IO.Path]::GetFileName($it) }
}
$mapped = $mapped | Select-Object -Unique
$extra = $files | Where-Object { $_ -notin $mapped }
$missing = $mapped | Where-Object { $_ -notin $files }
Write-Output "Mapped count: $($mapped.Count)"
Write-Output "Files in checks: $($files.Count)"
Write-Output "Extra files present (not mapped):"
foreach ($e in $extra) { Write-Output " - $e" }
Write-Output "Missing mapped files (mapped but not in checks):"
foreach ($m in $missing) { Write-Output " - $m" }
# search backups for missing and restore if found
$backupRootDir = Get-ChildItem -Path $checks -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'removed_unwanted_*' } | Sort-Object Name -Descending | Select-Object -First 1
if ($backupRootDir) { $backupRoot = $backupRootDir.FullName } else { $backupRoot = Join-Path $checks 'removed_unwanted' }
$unmappedBackupDir = Get-ChildItem -Path $checks -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'unmapped_backup_*' } | Sort-Object Name -Descending | Select-Object -First 1
if ($unmappedBackupDir) { $unmappedBackup = $unmappedBackupDir.FullName } else { $unmappedBackup = Join-Path $checks 'unmapped_backup' }
foreach ($m in $missing) {
    $found = Get-ChildItem -Path $checks -Recurse -Filter $m -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        if (Test-Path $unmappedBackup) { $found = Get-ChildItem -Path $unmappedBackup -Recurse -Filter $m -ErrorAction SilentlyContinue | Select-Object -First 1 }
    }
    if (-not $found) {
        if (Test-Path $backupRoot) { $found = Get-ChildItem -Path $backupRoot -Recurse -Filter $m -ErrorAction SilentlyContinue | Select-Object -First 1 }
    }
    if ($found) {
        Write-Output "Found missing mapped file in backup: $($found.FullName)"
        $dest = Join-Path $checks $found.Name
        Write-Output "Restoring to: $dest"
        try { Move-Item -Path $found.FullName -Destination $dest -Force; Write-Output 'Restored.' } catch { Write-Output "Restore failed: $($_.Exception.Message)" }
    }
}
# Summarize final counts
$files2 = Get-ChildItem -Path $checks -Filter '*.sql' -File | Select-Object -ExpandProperty Name
$extra2 = $files2 | Where-Object { $_ -notin $mapped }
Write-Output "After restore - Files in checks: $($files2.Count)"
Write-Output "Remaining extra files (not mapped):"
foreach ($e in $extra2) { Write-Output " - $e" }
Write-Output 'Done.'

