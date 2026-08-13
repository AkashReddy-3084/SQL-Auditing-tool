-- Checklist: Set-based operations preferred over row-by-row processing
-- Scope: DATABASE
-- Scoring: 0 = >50% of procedures contain RBAR keywords, 1 = 20-50%, 2 = <20% (or 0%), 3 = Fully compliant (not achievable via static analysis alone; capped at 2 due to proxy evidence limitations)
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
        DECLARE @Total INT = (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0 AND type = ''P'');
        DECLARE @Rbar INT = (SELECT COUNT(*) FROM sys.procedures p
                             JOIN sys.sql_modules m ON p.object_id = m.object_id
                             WHERE p.is_ms_shipped = 0 AND p.type = ''P''
                               AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'' OR m.definition LIKE ''%FETCH%'' OR m.definition LIKE ''%@@FETCH_STATUS%''));
        DECLARE @Pct FLOAT = CASE WHEN @Total = 0 THEN 0 ELSE CAST(@Rbar AS FLOAT) / @Total * 100 END;
        INSERT INTO #DbResults
        SELECT ''' + @DbName + ''', CASE
            WHEN @Pct > 50 THEN 0
            WHEN @Pct >= 20 THEN 1
            ELSE 2
        END;';
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