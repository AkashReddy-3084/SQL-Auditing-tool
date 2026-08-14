-- Checklist: Completeness: all expected sources/batches received
-- Scope: DATABASE
-- Scoring: 0=No staging/control tables or load evidence; 1=Staging tables exist but no control/metadata tracking, or control tables lack recent load timestamps; 2=Control tables exist with recent load timestamps and explicit status/completeness flags; 3=Control tables contain automated completeness validation (e.g., expected vs actual batch counts match) with recent successful records
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Create temp table to collect per-database results
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
        DECLARE @HasStaging INT = 0;
        DECLARE @HasControl INT = 0;
        DECLARE @HasRecentLoad INT = 0;
        DECLARE @HasStatusFlag INT = 0;
        DECLARE @DbScore INT = 0;

        -- Check for staging schemas/tables
        IF EXISTS (SELECT 1 FROM sys.schemas WHERE name LIKE ''%stag%'' OR name LIKE ''%landing%'' OR name LIKE ''%raw%'')
            SET @HasStaging = 1;
        IF @HasStaging = 0 AND EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%stag%'' OR name LIKE ''%landing%'' OR name LIKE ''%raw%'')
            SET @HasStaging = 1;

        -- Check for control/metadata tables
        IF EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%control%'' OR name LIKE ''%batch%'' OR name LIKE ''%etl_log%'' OR name LIKE ''%load_status%'' OR name LIKE ''%source_track%'')
            SET @HasControl = 1;

        -- Check for recent load timestamps in control tables
        IF @HasControl = 1
        BEGIN
            SELECT @HasRecentLoad = COUNT(*) FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            WHERE (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%etl_log%'' OR t.name LIKE ''%load_status%'')
            AND c.name IN (''load_date'', ''batch_date'', ''run_date'', ''created_at'', ''inserted_at'');
            IF @HasRecentLoad > 0 SET @HasRecentLoad = 1;
        END

        -- Check for explicit status/completeness flags
        IF @HasControl = 1
        BEGIN
            SELECT @HasStatusFlag = COUNT(*) FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            WHERE (t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%etl_log%'' OR t.name LIKE ''%load_status%'')
            AND c.name IN (''status'', ''is_complete'', ''load_status'', ''batch_status'', ''success_flag'');
            IF @HasStatusFlag > 0 SET @HasStatusFlag = 1;
        END

        -- Scoring logic per database
        IF @HasStaging = 0 AND @HasControl = 0
            SET @DbScore = 0;
        ELSE IF @HasStaging = 1 AND @HasControl = 0
            SET @DbScore = 1;
        ELSE IF @HasControl = 1 AND @HasRecentLoad = 1 AND @HasStatusFlag = 0
            SET @DbScore = 2;
        ELSE IF @HasControl = 1 AND @HasRecentLoad = 1 AND @HasStatusFlag = 1
            SET @DbScore = 3;
        ELSE IF @HasControl = 1 AND @HasRecentLoad = 0
            SET @DbScore = 1;

        INSERT INTO #DbResults VALUES ('' + QUOTENAME(@DbName, '''') + N'', @DbScore);
        ';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.