-- Checklist: Test environment representative of production (data, scale)
-- Scope: SERVER
-- Scoring: 0 = Production environment detected or test environment with negligible data/scale; 
--          1 = Test environment with minimal data; 
--          2 = Test environment with substantial data/scale (proxy for representativeness); 
--          3 = Not achievable (requires direct cross-environment comparison)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalRows BIGINT = 0;
DECLARE @TotalSizeMB BIGINT = 0;
DECLARE @ServerName NVARCHAR(256) = CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256));
DECLARE @EnvType NVARCHAR(10) = 'Unknown';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbMetrics (DbName NVARCHAR(256), DbRows BIGINT, DbSizeMB BIGINT);

-- Determine environment type from server name
IF @ServerName LIKE '%PROD%' OR @ServerName LIKE '%PRODUCTION%' SET @EnvType = 'PROD';
ELSE IF @ServerName LIKE '%TEST%' OR @ServerName LIKE '%QA%' OR @ServerName LIKE '%UAT%' SET @EnvType = 'TEST';
ELSE IF @ServerName LIKE '%DEV%' OR @ServerName LIKE '%DEVELOPMENT%' SET @EnvType = 'DEV';

-- Gather row counts and sizes per user database
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #DbMetrics
        SELECT ''' + @DbName + N''', 
               ISNULL((SELECT SUM(row_count) FROM sys.dm_db_partition_stats WHERE index_id IN (0, 1) AND object_id IN (SELECT object_id FROM sys.tables)), 0),
               ISNULL((SELECT SUM(size * 8 / 1024) FROM sys.database_files WHERE type IN (0, 1)), 0);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbMetrics VALUES (@DbName, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- FIX: Handle NULL from SUM when #DbMetrics is empty (no user databases)
SELECT @TotalRows = ISNULL(SUM(DbRows), 0), @TotalSizeMB = ISNULL(SUM(DbSizeMB), 0) FROM #DbMetrics;

-- Scoring logic
IF @EnvType = 'PROD'
BEGIN
    SET @Score = 0;
END
ELSE IF @EnvType IN ('TEST', 'QA', 'UAT', 'DEV', 'Unknown')
BEGIN
    IF @TotalRows >= 1000000 AND @TotalSizeMB >= 10240
        SET @Score = 2;
    ELSE IF @TotalRows >= 100000 AND @TotalSizeMB >= 1024
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

-- Note: Per checklist scoring logic, Score 3 = Not achievable (requires direct cross-environment comparison).
-- This script uses a best-effort proxy (Scores 0-2). If strict compliance requires cross-env validation,
-- override @Score = 3 and @Result = 'Pass' (or 'Fail' per your framework's policy for unachievable checks).
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbMetrics;

SELECT @Result AS Result, @Score AS Score;