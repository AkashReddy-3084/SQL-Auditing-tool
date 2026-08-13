-- Checklist: Temporal tables / change tracking used for data history where required
-- Scope: DATABASE
-- Scoring: 0=Neither configured, 1=One feature enabled, 2=Both enabled, 3=Extensive usage (capped at 2 due to business context requirement)
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
        DECLARE @CtOn INT = 0;
        DECLARE @CtTables INT = 0;
        DECLARE @TemporalTables INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @CtOn = ISNULL(CAST(DATABASEPROPERTYEX(DB_NAME(), ''IsChangeTrackingEnabled'') AS INT), 0);
        SELECT @CtTables = COUNT(*) FROM sys.change_tracking_tables;
        SELECT @TemporalTables = COUNT(*) FROM sys.tables WHERE temporal_type > 0;

        IF @CtOn = 1 AND @CtTables > 0 AND @TemporalTables > 0 SET @DbScore = 2;
        ELSE IF @CtOn = 1 OR @TemporalTables > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC(@Sql);
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