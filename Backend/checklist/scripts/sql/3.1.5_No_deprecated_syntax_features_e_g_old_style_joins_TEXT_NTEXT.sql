-- Checklist: No deprecated syntax/features (e.g., old-style joins, TEXT/NTEXT)
-- Scope: DATABASE
-- Scoring: 3=Zero deprecated types/syntax found; 2=1-5 occurrences; 1=6-20 occurrences; 0=>20 occurrences
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
        DECLARE @DeprecatedCount INT = 0;
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @Cnt = 
            (SELECT COUNT(*) FROM sys.columns c JOIN sys.types t ON c.user_type_id = t.user_type_id WHERE t.name IN (''text'', ''ntext'', ''image''))
            + (SELECT COUNT(*) FROM sys.sql_modules m WHERE m.definition IS NOT NULL AND m.definition LIKE ''%= %'');';
        EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @DeprecatedCount OUTPUT;

        DECLARE @DbScore INT = CASE
            WHEN @DeprecatedCount = 0 THEN 3
            WHEN @DeprecatedCount BETWEEN 1 AND 5 THEN 2
            WHEN @DeprecatedCount BETWEEN 6 AND 20 THEN 1
            ELSE 0
        END;
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