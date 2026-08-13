-- Checklist: Incremental load implemented where applicable (watermark / CDC / Change Tracking)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=DB-level feature enabled but no tables configured, 2=Watermark columns found (proxy evidence), 3=CDC or Change Tracking enabled on tables
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
        DECLARE @DbCdc INT = 0;
        DECLARE @DbCt INT = 0;
        DECLARE @CdcTables INT = 0;
        DECLARE @CtTables INT = 0;
        DECLARE @WatermarkTables INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @DbCdc = ISNULL(CONVERT(INT, value), 0) FROM sys.database_properties WHERE name = ''is_cdc_enabled'';
        SELECT @DbCt = ISNULL(CONVERT(INT, value), 0) FROM sys.database_properties WHERE name = ''is_change_tracking_on'';

        SELECT @CdcTables = COUNT(*) FROM sys.tables WHERE is_tracked_by_cdc = 1;
        
        IF OBJECT_ID(''sys.change_tracking_tables'') IS NOT NULL
            SELECT @CtTables = COUNT(*) FROM sys.change_tracking_tables;

        SELECT @WatermarkTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.columns c ON t.object_id = c.object_id
        WHERE c.name LIKE ''%update%'' OR c.name LIKE ''%modified%'' OR c.name LIKE ''%watermark%'' OR c.name LIKE ''%etl%'' OR c.name LIKE ''%load_date%'';

        IF @CdcTables > 0 OR @CtTables > 0
            SET @DbScore = 3;
        ELSE IF @WatermarkTables > 0
            SET @DbScore = 2;
        ELSE IF @DbCdc = 1 OR @DbCt = 1
            SET @DbScore = 1;
        ELSE
            SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;