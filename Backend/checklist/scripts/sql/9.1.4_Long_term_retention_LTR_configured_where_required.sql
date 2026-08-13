-- Checklist: Long-term retention (LTR) configured where required
-- Scope: DATABASE
-- Scoring: 0=No LTR evidence, 1=Partial (backup history <30d or missing policy), 2=Policy configured OR long-term backups exist, 3=Policy configured AND long-term backups verified
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

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
        DECLARE @HasPolicy INT = 0;
        DECLARE @HasLongBackups INT = 0;
        DECLARE @HasRecentBackups INT = 0;

        -- Check for explicit LTR policy (extended properties)
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE name LIKE ''%LTR%'' OR name LIKE ''%LongTermRetention%'')
            SET @HasPolicy = 1;

        -- Check for long-term backup history (>30 days)
        IF EXISTS (
            SELECT 1 FROM msdb.dbo.backupset b
            WHERE b.database_name = DB_NAME()
            AND b.backup_start_date < DATEADD(DAY, -30, GETDATE())
            AND b.type IN (''D'',''I'',''L'')
        )
            SET @HasLongBackups = 1;

        -- Check for recent backup history (<30 days) to enable partial scoring
        IF EXISTS (
            SELECT 1 FROM msdb.dbo.backupset b
            WHERE b.database_name = DB_NAME()
            AND b.backup_start_date >= DATEADD(DAY, -30, GETDATE())
            AND b.type IN (''D'',''I'',''L'')
        )
            SET @HasRecentBackups = 1;

        SELECT @DbScore = CASE
            WHEN @HasPolicy = 1 AND @HasLongBackups = 1 THEN 3
            WHEN @HasPolicy = 1 OR @HasLongBackups = 1 THEN 2
            WHEN @HasRecentBackups = 1 OR @HasPolicy = 1 THEN 1
            ELSE 0
        END;';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
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