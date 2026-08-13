-- Checklist: Unique constraints on natural/business keys where appropriate
-- Scope: DATABASE
-- Scoring: 0 = 0% of tables have unique constraints/indexes; 1 = 1-24%; 2 = 25-74%; 3 = 75-100%. NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TablesWithUnique INT;
        DECLARE @Pct FLOAT;
        DECLARE @DbScore INT;

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        
        SELECT @TablesWithUnique = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        WHERE EXISTS (
            SELECT 1 FROM sys.key_constraints kc WHERE kc.parent_object_id = t.object_id AND kc.type = ''UQ''
        ) OR EXISTS (
            SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_unique = 1 AND i.is_primary_key = 0
        );

        IF @TotalTables = 0 SET @DbScore = 3;
        ELSE BEGIN
            SET @Pct = (@TablesWithUnique * 100.0) / @TotalTables;
            SET @DbScore = CASE 
                WHEN @Pct >= 75 THEN 3 
                WHEN @Pct >= 25 THEN 2 
                WHEN @Pct >= 1 THEN 1 
                ELSE 0 
            END;
        END;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;