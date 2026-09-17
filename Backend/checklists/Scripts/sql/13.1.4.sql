-- Checklist: Known issues and tech debt registered
-- Scope: DATABASE
-- Scoring: 3 = a populated issue/tech-debt registry table exists; 2 = registry table exists but is empty, or 5 or more objects carry known-issue/tech-debt extended properties; 1 = only uncatalogued inline code markers; 0 = no registry, properties or markers found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'No issue or technical-debt registry evidence was found in the current database';
DECLARE @RegTables INT = 0;
DECLARE @RegRows BIGINT = 0;
DECLARE @RegNames NVARCHAR(MAX) = '';
DECLARE @Props INT = 0;
DECLARE @Markers INT = 0;

BEGIN TRY
    ;WITH r AS
    (
        SELECT t.object_id,
               QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name) AS FullName
        FROM sys.tables AS t
        WHERE t.is_ms_shipped = 0
          AND (t.name LIKE '%issue%' OR t.name LIKE '%defect%' OR t.name LIKE '%tech%debt%'
            OR t.name LIKE '%backlog%' OR t.name LIKE '%known%error%' OR t.name LIKE '%remediation%'
            OR t.name LIKE '%risk%register%' OR t.name LIKE '%workaround%')
    )
    SELECT @RegTables = COUNT(*),
           @RegRows = ISNULL(SUM(x.RowCnt), 0),
           @RegNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), r.FullName), ', '), 400), '')
    FROM r
    OUTER APPLY
    (
        SELECT ISNULL(SUM(ps.row_count), 0) AS RowCnt
        FROM sys.dm_db_partition_stats AS ps
        WHERE ps.object_id = r.object_id AND ps.index_id IN (0, 1)
    ) AS x;

    SELECT @Props = COUNT(*)
    FROM sys.extended_properties AS ep
    WHERE ep.name LIKE '%issue%' OR ep.name LIKE '%debt%' OR ep.name LIKE '%todo%'
       OR CONVERT(NVARCHAR(MAX), ep.value) LIKE '%known issue%'
       OR CONVERT(NVARCHAR(MAX), ep.value) LIKE '%tech%debt%'
       OR CONVERT(NVARCHAR(MAX), ep.value) LIKE '%workaround%'
       OR CONVERT(NVARCHAR(MAX), ep.value) LIKE '%TODO%';

    SELECT @Markers = COUNT(*)
    FROM sys.sql_modules AS m
    JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND (m.definition LIKE '%TODO%' OR m.definition LIKE '%FIXME%' OR m.definition LIKE '%HACK%'
        OR m.definition LIKE '%tech%debt%' OR m.definition LIKE '%known issue%');
END TRY
BEGIN CATCH
    SET @RegTables = 0;
    SET @Props = 0;
    SET @Markers = 0;
END CATCH;

SET @Score = CASE
                WHEN @RegTables > 0 AND @RegRows > 0 THEN 3
                WHEN @RegTables > 0 OR @Props >= 5 THEN 2
                WHEN @Props > 0 OR @Markers > 0 THEN 1
                ELSE 0
             END;

SET @Finding = CASE
    WHEN @RegTables > 0
        THEN CONCAT(@RegTables, ' issue/tech-debt registry table(s) found holding ', @RegRows,
                    ' registered row(s): ', @RegNames, '; documenting extended properties = ', @Props,
                    ', code markers (TODO/FIXME/HACK) = ', @Markers)
    WHEN @Props > 0 OR @Markers > 0
        THEN CONCAT('No issue/tech-debt registry table found; ', @Props,
                    ' extended propert(ies) reference known issues or debt and ', @Markers,
                    ' module(s) contain TODO/FIXME/HACK markers that are not tracked in a registry')
    ELSE 'No issue/tech-debt registry table, no known-issue extended properties and no TODO/FIXME/HACK markers were found in this database'
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;