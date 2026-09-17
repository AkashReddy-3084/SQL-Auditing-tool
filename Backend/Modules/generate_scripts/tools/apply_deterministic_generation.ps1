<#
Reads deterministic-script-mapping.json and attempts to generate a deterministic
SQL script for each checklist item using filename-based heuristics. If a script
can be generated it is written to the configured path. If not, the mapping
entry and any placeholder file are removed (so no placeholder scripts remain).

This is a one-off operator script — it uses simple heuristics and should be
reviewed. It does not integrate into the application.
#>
param([string[]]$ChecklistIds = @())

Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
# This script lives in Backend/Modules/generate_scripts/tools.
$backendDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir))
$workspaceRoot = Split-Path -Parent $backendDir
$checklistDir = Join-Path $backendDir 'checklists'
$scriptsDir = Join-Path $checklistDir 'Scripts'
$mappingPath = Join-Path $checklistDir 'deterministic-script-mapping.json'
if (-not (Test-Path $mappingPath)) { Write-Error "Mapping not found: $mappingPath"; exit 2 }

$map = @{}
$checklistDescriptions = @{}
if (Test-Path $mappingPath) {
    $rawMap = Get-Content -Raw -Path $mappingPath | ConvertFrom-Json
    if ($rawMap) {
        $props = @($rawMap.PSObject.Properties)
        if ($props.Count -gt 0) {
            foreach ($prop in $props) {
                $map[$prop.Name] = @($prop.Value)
            }
        }
    }
}

$checklistJsonPath = Join-Path $checklistDir 'master-checklist.json'
if (Test-Path $checklistJsonPath) {
    $checklistJson = Get-Content -Raw -Path $checklistJsonPath | ConvertFrom-Json
    foreach ($area in $checklistJson.areas) {
        foreach ($subArea in $area.sub_areas) {
            foreach ($item in $subArea.items) {
                if ($item.id) {
                    $checklistDescriptions[$item.id] = $item.text
                    $textValue = if ($null -ne $item.text) { [string]$item.text } else { '' }
                    $textLower = $textValue.ToLower()
                    if ($textLower -match 'primary key' -or
                        $textLower -match 'select \*|no select|explicit column lists' -or
                        $textLower -match 'query store' -or
                        $textLower -match 'transparent data encryption|tde|encryption at rest' -or
                        $textLower -match 'deadlock' -or
                        $textLower -match 'dbcc checkdb|consistency check' -or
                        $textLower -match 'backup' -or
                        $textLower -match 'auto-update stats|auto update stats|auto-create statistics|statistics' -or
                        $textLower -match 'sql agent|agent job|job failures|job run history|scheduler jobs' -or
                        $textLower -match 'hardcoded|credential' -or
                        $textLower -match 'foreign key' -or
                        $textLower -match 'unique constraint' -or
                        $textLower -match 'check constraint' -or
                        $textLower -match 'not null' -or
                        $textLower -match 'tls|encrypt true' -or
                        $textLower -match 'dynamic data masking|masking') {
                        $map[$item.id] = @($item.id + '.sql')
                    }
                }
            }
        }
    }
}

$resolvedChecklistIds = [System.Collections.Generic.List[string]]::new()
if ($ChecklistIds) {
    foreach ($entry in $ChecklistIds) {
        foreach ($part in ($entry -split '[,;]')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $resolvedChecklistIds.Add($trimmed) }
        }
    }
}
if ($resolvedChecklistIds.Count -gt 0) {
    foreach ($id in $resolvedChecklistIds) {
        $map[$id] = @($id + '.sql')
    }
}

if ($map.Count -eq 0) {
    $sqlDir = Join-Path $scriptsDir 'sql'
    if (Test-Path $sqlDir) {
        foreach ($file in Get-ChildItem -Path $sqlDir -Filter *.sql -File | Sort-Object Name) {
            $id = [regex]::Match($file.BaseName, '^\d+(?:\.\d+)+').Value
            if ($id) { $map[$id] = @($file.FullName) }
        }
    }
}

$newMap = @{}
$created = [System.Collections.ArrayList]::new()
$updated = [System.Collections.ArrayList]::new()
$removed = [System.Collections.ArrayList]::new()

$knownOutputNames = @{
    '3.1.2' = '3.1.2_No_SELECT_in_production_code_explicit_column_lists.sql'
    '4.5.1' = '4.5.1_Primary_keys_defined_on_all_tables.sql'
    '6.2.1' = '6.2.1_Transparent_Data_Encryption_TDE_enabled_for_encryption_at_rest.sql'
    '10.2.1' = '10.2.1_Query_Store_enabled_and_configured_appropriately.sql'
    '10.3.2' = '10.3.2_Deadlock_capture_configured.sql'
    '9.3.1' = '9.3.1_Consistency_checks_DBCC_CHECKDB_scheduled_and_monitored_SQL_Server_MI.sql'
    '9.1.1' = '9.1.1_Backup_strategy_defined_and_matches_RPO_full_differential_log_or_PaaS_automated.sql'
    '6.4.2' = '6.4.2_No_credentials_hardcoded_in_ETL_packages_scripts_or_linked_servers.sql'
    '10.4.2' = '10.4.2_Job_failures_alert_the_responsible_team.sql'
    '14.5.1' = '14.5.1_Statistics_kept_current_auto_update_on_plus_manual_updates_after_large_loads.sql'
}

function Get-OutputFileName([string]$id, [string]$fallback, [string]$description) {
    if ($knownOutputNames.ContainsKey($id)) { return $knownOutputNames[$id] }
    if ($description) {
        $slug = $description.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
        $slug = $slug.Trim('_')
        if ($slug) { return $id + '_' + $slug.Substring(0, [Math]::Min(70, $slug.Length)) + '.sql' }
    }
    return $fallback
}

function Write-SqlFile([string]$path, [string]$sql) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sql | Out-File -FilePath $path -Encoding utf8 -Force
}

function Generate-SqlFor([string]$id, [string]$fileNameLower) {
    # Return SQL string or $null if none
    # Heuristic patterns
    if ($fileNameLower -match 'query[_-]?store|querystore') {
        return @"
SET NOCOUNT ON;
-- Check for Query Store presence (SQL Server/Managed Instance)
IF EXISTS (SELECT 1 FROM sys.database_query_store_options)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
"@
    }

    if ($fileNameLower -match 'transparent|tde|encryption_at_rest|tde_enabled') {
        return @"
SET NOCOUNT ON;
-- Check Transparent Data Encryption enabled for current database
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.dm_database_encryption_keys dek WHERE dek.database_id = DB_ID() AND dek.encryption_state = 3
) THEN 'Passed' ELSE 'Failed' END AS Result;
"@
    }

    if ($fileNameLower -match 'backup|backups|backup_preference|backup_failures') {
        return @"
SET NOCOUNT ON;
-- Check for a recent full database backup in last 7 days
IF EXISTS(
    SELECT 1 FROM msdb.dbo.backupset b WHERE b.database_name = DB_NAME() AND b.type = 'D' AND b.backup_finish_date > DATEADD(day,-7,GETDATE())
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
"@
    }

    if ($fileNameLower -match 'deadlock|deadlocks|deadlock_capture') {
        return @"
SET NOCOUNT ON;
-- Check for Extended Events system_health session (deadlocks captured by system session)
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'system_health') THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'dbcc_checkdb|consistency_check|consistency_checks') {
        return @"
SET NOCOUNT ON;
-- Check if any SQL Agent job contains DBCC CHECKDB command (proxy for scheduled consistency checks)
IF EXISTS(
    SELECT 1 FROM msdb.dbo.sysjobsteps s WHERE s.command LIKE '%DBCC CHECKDB%'
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'NeedsReview' AS Result;
"@
    }

    if ($fileNameLower -match 'auto[_-]?update[_-]?stats|statistics_kept_current|auto_create_statistics') {
        return @"
SET NOCOUNT ON;
-- Check auto-update stats database option
SELECT CASE WHEN DATABASEPROPERTYEX(DB_NAME(),'IsAutoUpdateStatistics') = 1 THEN 'Passed' ELSE 'Failed' END AS Result;
"@
    }

    if ($fileNameLower -match 'sql[_-]?agent|job|job_failures|job_run_history') {
        return @"
SET NOCOUNT ON;
-- Check whether SQL Agent jobs exist for this DB (requires msdb access)
SELECT CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'no_credentials_hardcoded|no_credentials|no_hardcoded') {
        return @"
SET NOCOUNT ON;
-- Heuristic: search code for common credential keywords (may produce false positives)
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.sql_modules m WHERE m.definition LIKE '%password=%' OR m.definition LIKE '%pwd=%' OR m.definition LIKE '%credential%'
) THEN 'NeedsReview' ELSE 'Passed' END AS Result;
"@
    }

    if ($fileNameLower -match 'foreign[_-]?keys|foreignkeys') {
        return @"
SET NOCOUNT ON;
-- Check whether the database contains any foreign keys
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.foreign_keys) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'unique[_-]?constraints|uniqueconstraints') {
        return @"
SET NOCOUNT ON;
-- Check whether the database contains any unique constraints
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.objects o JOIN sys.indexes i ON i.object_id = o.object_id WHERE o.type = 'U' AND i.is_unique_constraint = 1) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'check[_-]?constraints|checkconstraints') {
        return @"
SET NOCOUNT ON;
-- Check whether the database contains any check constraints
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.check_constraints) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'not[_-]?null|notnull') {
        return @"
SET NOCOUNT ON;
-- Check whether any nullable columns exist on user tables
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_ms_shipped = 0 AND c.is_nullable = 1
) THEN 'NeedsReview' ELSE 'Passed' END AS Result;
"@
    }

    if ($fileNameLower -match 'tls|encrypt_true') {
        return @"
SET NOCOUNT ON;
-- Check whether force encryption is enabled at the server level
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.configurations WHERE name LIKE '%encryption%' AND convert(int, value_in_use) = 1
) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'masking|dynamic') {
        return @"
SET NOCOUNT ON;
-- Check whether any masked columns exist
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.masked_columns) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'primary[_-]?keys|primarykeys') {
        return @"
SET NOCOUNT ON;
-- Passed when every user table has a primary key
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.tables t
    WHERE t.is_ms_shipped = 0
    AND NOT EXISTS(
        SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1
    )
) THEN 'Failed' ELSE 'Passed' END AS Result;
"@
    }

    if ($fileNameLower -match 'select\s*_?\*|no_select') {
        return @"
SET NOCOUNT ON;
-- Fail if any stored procedure/object contains a literal 'SELECT *'
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.sql_modules m
    WHERE m.definition LIKE '%SELECT %*%'
) THEN 'Failed' ELSE 'Passed' END AS Result;
"@
    }

    if ($fileNameLower -match 'query[_-]?store|querystore') {
        return @"
SET NOCOUNT ON;
-- Check for Query Store presence (SQL Server/Managed Instance)
IF EXISTS (SELECT 1 FROM sys.database_query_store_options)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
"@
    }

    if ($fileNameLower -match 'transparent|tde|encryption_at_rest|tde_enabled') {
        return @"
SET NOCOUNT ON;
-- Check Transparent Data Encryption enabled for current database
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.dm_database_encryption_keys dek WHERE dek.database_id = DB_ID() AND dek.encryption_state = 3
) THEN 'Passed' ELSE 'Failed' END AS Result;
"@
    }

    if ($fileNameLower -match 'deadlock|deadlocks|deadlock_capture') {
        return @"
SET NOCOUNT ON;
-- Check for Extended Events system_health session (deadlocks captured by system session)
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'system_health') THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'dbcc_checkdb|consistency_check|consistency_checks') {
        return @"
SET NOCOUNT ON;
-- Check if any SQL Agent job contains DBCC CHECKDB command (proxy for scheduled consistency checks)
IF EXISTS(
    SELECT 1 FROM msdb.dbo.sysjobsteps s WHERE s.command LIKE '%DBCC CHECKDB%'
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'NeedsReview' AS Result;
"@
    }

    if ($fileNameLower -match 'backup|backups|backup_preference|backup_failures') {
        return @"
SET NOCOUNT ON;
-- Check for a recent full database backup in last 7 days
IF EXISTS(
    SELECT 1 FROM msdb.dbo.backupset b WHERE b.database_name = DB_NAME() AND b.type = 'D' AND b.backup_finish_date > DATEADD(day,-7,GETDATE())
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
"@
    }

    if ($fileNameLower -match 'auto[_-]?update[_-]?stats|statistics_kept_current|auto_create_statistics') {
        return @"
SET NOCOUNT ON;
-- Check auto-update stats database option
SELECT CASE WHEN DATABASEPROPERTYEX(DB_NAME(),'IsAutoUpdateStatistics') = 1 THEN 'Passed' ELSE 'Failed' END AS Result;
"@
    }

    if ($fileNameLower -match 'sql[_-]?agent|job|job_failures|job_run_history') {
        return @"
SET NOCOUNT ON;
-- Check whether SQL Agent jobs exist for this DB (requires msdb access)
SELECT CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
"@
    }

    if ($fileNameLower -match 'no_credentials_hardcoded|no_credentials|no_hardcoded') {
        return @"
SET NOCOUNT ON;
-- Heuristic: search code for common credential keywords (may produce false positives)
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.sql_modules m WHERE m.definition LIKE '%password=%' OR m.definition LIKE '%pwd=%' OR m.definition LIKE '%credential%'
) THEN 'NeedsReview' ELSE 'Passed' END AS Result;
"@
    }

    # Generic fallback: unable to determine an automated check
    return $null
}

$keys = @($map.Keys | Sort-Object)
foreach ($key in $keys) {
    $paths = $map[$key]
    if ($paths -eq $null -or $paths.Count -eq 0) { continue }

    $sqlDir = Join-Path $scriptsDir 'sql'
    $fallbackName = $key + '.sql'
    $descriptionText = ''
    if ($checklistDescriptions.ContainsKey($key)) { $descriptionText = $checklistDescriptions[$key] }
    $outputFileName = Get-OutputFileName $key $fallbackName $descriptionText
    $full = Join-Path $sqlDir $outputFileName
    $relativeTarget = 'Backend/checklists/Scripts/sql/' + $outputFileName
    $fileNameLower = $outputFileName.ToLower()

    $sql = Generate-SqlFor $key $fileNameLower
    if ($sql) {
        Write-Output ("Generating SQL for " + $key + " -> " + $relativeTarget)
        Write-SqlFile -path $full -sql $sql
        $newMap[$key] = @($relativeTarget)
        if (Test-Path $full) {
            $created.Add($full) | Out-Null
        }
        $updated.Add($relativeTarget) | Out-Null
    } else {
        Write-Output ("No deterministic SQL for " + $key + " - removing mapping and file if present")
        if (Test-Path $full) { Remove-Item -LiteralPath $full -Force; $removed.Add($full) | Out-Null }
    }
}

# Persist updated mapping
$newJson = $newMap | ConvertTo-Json -Depth 4
Out-File -FilePath $mappingPath -Encoding utf8 -InputObject $newJson -Force
