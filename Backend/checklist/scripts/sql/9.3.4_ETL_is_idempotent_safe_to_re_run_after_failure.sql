-- Checklist: ETL is idempotent — safe to re-run after failure
-- Scope: SERVER
-- Scoring: 0=No ETL procs found or <20% show idempotency patterns, 1=20-59% show patterns, 2=>=60% show patterns, 3=Reserved for fully verifiable checks (capped at 2 here due to proxy/static analysis nature).
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @TotalETL INT = 0;
DECLARE @IdempotentETL INT = 0;

CREATE TABLE #ETLChecks (DbName NVARCHAR(256), ProcName NVARCHAR(256), IsIdempotent BIT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #ETLChecks
        SELECT ''' + @DbName + N''', p.name,
            CASE WHEN m.definition LIKE ''%MERGE%''
                 OR m.definition LIKE ''%TRUNCATE TABLE%''
                 OR m.definition LIKE ''%DELETE FROM%''
                 OR m.definition LIKE ''%IF EXISTS%''
            THEN 1 ELSE 0 END
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.name LIKE ''%etl%'' OR p.name LIKE ''%load%'' OR p.name LIKE ''%sync%''
           OR p.name LIKE ''%import%'' OR p.name LIKE ''%staging%'' OR p.name LIKE ''%ods%''
           OR p.name LIKE ''%dw%'' OR p.name LIKE ''%mart%'';';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Skip databases where we lack permissions or errors occur
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @TotalETL = COUNT(*), @IdempotentETL = SUM(IsIdempotent) FROM #ETLChecks;

IF @TotalETL = 0
    SET @Score = 0;
ELSE
BEGIN
    DECLARE @Pct FLOAT = CAST(@IdempotentETL AS FLOAT) / @TotalETL;
    IF @Pct >= 0.6 SET @Score = 2;
    ELSE IF @Pct >= 0.2 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #ETLChecks;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.