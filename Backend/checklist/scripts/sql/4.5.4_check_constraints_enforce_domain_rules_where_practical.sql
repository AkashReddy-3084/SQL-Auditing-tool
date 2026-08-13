-- Checklist: Check constraints enforce domain rules where practical
-- Scope: DATABASE
-- Scoring: 0 = 0% coverage; 1 = 1-30%; 2 = 31-70%; 3 = 71-100% of user tables have check constraints
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
        DECLARE @TotalTables INT;
        DECLARE @TablesWithChecks INT;
        DECLARE @Pct FLOAT;
        DECLARE @DbScore INT;

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        SELECT @TablesWithChecks = COUNT(DISTINCT parent_object_id) FROM sys.check_constraints;

        IF @TotalTables = 0
            SET @DbScore = 3;
        ELSE
        BEGIN
            SET @Pct = (@TablesWithChecks * 100.0) / @TotalTables;
            SET @DbScore = CASE
                WHEN @Pct >= 71 THEN 3
                WHEN @Pct >= 31 THEN 2
                WHEN @Pct >= 1 THEN 1
                ELSE 0
            END;
        END;

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore);
        ';
        EXEC sp_executesql @Sql;
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
-- NOTE: This script measures check constraint coverage. Semantic validation of domain rules requires human review.