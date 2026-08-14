-- Checklist: Dynamic SQL, where used, is parameterized (sp_executesql) — no injection risk
-- Scope: DATABASE
-- Scoring: 0=All dynamic SQL uses unsafe concatenation; 1=Mix of safe/unsafe; 2=All uses sp_executesql; 3=No dynamic SQL found
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
        DECLARE @Unsafe INT = 0, @Safe INT = 0;
        SELECT @Unsafe = COUNT(*) FROM sys.sql_modules 
        WHERE (definition LIKE ''%EXEC % + %'' OR definition LIKE ''%EXECUTE % + %'')
          AND definition NOT LIKE ''%sp_executesql%'';
        SELECT @Safe = COUNT(*) FROM sys.sql_modules 
        WHERE definition LIKE ''%sp_executesql%'';
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', 
            CASE 
                WHEN @Unsafe > 0 AND @Safe = 0 THEN 0
                WHEN @Unsafe > 0 AND @Safe > 0 THEN 1
                WHEN @Unsafe = 0 AND @Safe > 0 THEN 2
                ELSE 3
            END);';
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