-- Checklist: Row-Level Security implemented where multi-tenant/segmented access is required
-- Scope: DATABASE
-- Scoring: 0 = No RLS predicates found. 1 = RLS found on 1-2 tables. 2 = RLS found on 3+ tables. 3 = Capped at 2 due to proxy evidence requiring human validation.
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
        DECLARE @Count INT = 0;
        IF OBJECT_ID(''sys.security_predicates'') IS NOT NULL
            SELECT @Count = COUNT(DISTINCT object_id) FROM sys.security_predicates;
        SELECT @Count;';
        
        DECLARE @Count INT;
        EXEC sp_executesql @Sql, N'@Count INT OUTPUT', @Count OUTPUT;
        
        DECLARE @DbScore INT = CASE 
            WHEN @Count = 0 THEN 0
            WHEN @Count BETWEEN 1 AND 2 THEN 1
            ELSE 2
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