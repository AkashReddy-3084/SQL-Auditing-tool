-- Checklist: Storage growth monitored; autogrowth settings sane (fixed size, not tiny %)
-- Scope: DATABASE
-- Scoring: 0=<20% sane, 1=20-49%, 2=50-89%, 3=>=90% sane files. Sane = fixed growth (not %) >= 100MB. +1 if monitoring job found (max 3).
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @TotalFiles INT = 0;
DECLARE @SaneFiles INT = 0;

CREATE TABLE #FileChecks (DbName NVARCHAR(256), TotalFiles INT, SaneFiles INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT ''' + @DbName + N''' AS DbName,
               COUNT(*) AS TotalFiles,
               SUM(CASE WHEN is_percent_growth = 0 
                        AND growth > 0 
                        AND (CASE WHEN type = 1 THEN growth ELSE growth * 8.0 / 1024 END) >= 100
                   THEN 1 ELSE 0 END) AS SaneFiles
        FROM sys.database_files;';
        INSERT INTO #FileChecks EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #FileChecks VALUES (@DbName, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @TotalFiles = SUM(TotalFiles), @SaneFiles = SUM(SaneFiles) FROM #FileChecks;

IF @TotalFiles > 0
BEGIN
    DECLARE @Pct FLOAT = CAST(@SaneFiles AS FLOAT) / @TotalFiles * 100;
    IF @Pct >= 90 SET @Score = 3;
    ELSE IF @Pct >= 50 SET @Score = 2;
    ELSE IF @Pct >= 20 SET @Score = 1;
    ELSE SET @Score = 0;
END
ELSE
BEGIN
    SET @Score = 0;
END

-- Check for storage/disk monitoring job (safe for Azure SQL fallback)
DECLARE @HasMonitoring BIT = 0;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%disk%' OR name LIKE '%space%' OR name LIKE '%growth%' OR name LIKE '%autogrowth%')
        SET @HasMonitoring = 1;
END TRY
BEGIN CATCH
    SET @HasMonitoring = 0;
END CATCH

IF @HasMonitoring = 1 AND @Score < 3 SET @Score = @Score + 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #FileChecks;
SELECT @Result AS Result, @Score AS Score;