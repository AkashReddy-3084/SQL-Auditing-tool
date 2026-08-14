-- Checklist: Sensitive data classified (SQL Data Discovery & Classification / labels)
-- Scope: DATABASE
-- Scoring: 0 = No classified columns found; 1 = 1-10 classified columns; 2 = 11-100 classified columns; 3 = >100 classified columns.
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
        DECLARE @Cnt INT = 0;
        IF OBJECT_ID(''sys.sensitivity_classifications'') IS NOT NULL
            SELECT @Cnt = COUNT(*) FROM sys.sensitivity_classifications;
        SELECT CASE 
            WHEN @Cnt = 0 THEN 0
            WHEN @Cnt BETWEEN 1 AND 10 THEN 1
            WHEN @Cnt BETWEEN 11 AND 100 THEN 2
            ELSE 3
        END;';
        INSERT INTO #DbResults (DbName, DbScore)
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