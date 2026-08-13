-- Checklist: Cross-layer reconciliation (mart vs integration vs source counts)
-- Scope: DATABASE
-- Scoring: 0=No relevant layer schemas found; 1=Layer schemas exist but no reconciliation evidence; 2=Found reconciliation metadata/ETL keywords; 3=Found dedicated reconciliation tables/procedures logging counts
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @LayerCount INT = 0;
        DECLARE @MetaCount INT = 0;
        DECLARE @ProcCount INT = 0;
        DECLARE @ReconTableCount INT = 0;

        -- Check for layer schemas
        SELECT @LayerCount = COUNT(DISTINCT s.name)
        FROM sys.schemas s
        WHERE s.name LIKE ''%mart%'' OR s.name LIKE ''%integration%'' OR s.name LIKE ''%source%'' OR s.name LIKE ''%staging%'' OR s.name LIKE ''%ods%'';

        -- Check for reconciliation metadata in extended properties
        SELECT @MetaCount = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.tables t ON ep.major_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE (s.name LIKE ''%mart%'' OR s.name LIKE ''%integration%'' OR s.name LIKE ''%source%'')
          AND (CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%reconcile%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%count%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%verify%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%match%'');

        -- Check for ETL procedures with reconciliation logic
        SELECT @ProcCount = COUNT(*)
        FROM sys.procedures p
        CROSS APPLY sys.sql_modules m
        WHERE p.object_id = m.object_id
          AND (m.definition LIKE ''%reconcile%'' OR m.definition LIKE ''%count%'' OR m.definition LIKE ''%verify%'' OR m.definition LIKE ''%compare%'');

        -- Check for dedicated reconciliation tables
        SELECT @ReconTableCount = COUNT(*)
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''%reconcile%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%control%'';

        DECLARE @DbScore INT = 0;
        IF @LayerCount = 0 SET @DbScore = 0;
        ELSE IF @MetaCount = 0 AND @ProcCount = 0 AND @ReconTableCount = 0 SET @DbScore = 1;
        ELSE IF @ReconTableCount > 0 SET @DbScore = 3;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;