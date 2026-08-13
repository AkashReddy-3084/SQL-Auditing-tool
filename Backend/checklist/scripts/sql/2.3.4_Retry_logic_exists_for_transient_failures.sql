DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobRetryCount INT = 0;
DECLARE @ProcRetryCount INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Check SQL Agent Jobs for retry attempts (on-prem/MI only)
IF DB_ID('msdb') IS NOT NULL
BEGIN
    SELECT @JobRetryCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.retry_attempts > 0;
END

-- Check procedures across user databases for retry patterns
CREATE TABLE #ProcRetries (DbName NVARCHAR(256), ProcCount INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #ProcRetries
        SELECT ''' + @DbName + N''', COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%RETRY%''
           OR (m.definition LIKE ''%WHILE%'' AND m.definition LIKE ''%ERROR%'')
           OR (m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WAITFOR%'');';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #ProcRetries VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @ProcRetryCount = ISNULL(SUM(ProcCount), 0) FROM #ProcRetries;
DROP TABLE #ProcRetries;

DECLARE @TotalEvidence INT = ISNULL(@JobRetryCount, 0) + ISNULL(@ProcRetryCount, 0);

SET @Score = CASE 
    WHEN @TotalEvidence = 0 THEN 0 
    WHEN @TotalEvidence BETWEEN 1 AND 4 THEN 1 
    WHEN @TotalEvidence BETWEEN 5 AND 19 THEN 2 
    ELSE 2 
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;