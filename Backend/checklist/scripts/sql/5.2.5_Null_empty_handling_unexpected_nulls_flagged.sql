-- Checklist: Null/empty handling: unexpected nulls flagged
-- Scope: DATABASE
-- Scoring: 0=No staging tables or 0% have validation artifacts, 1=1-25% have artifacts, 2=26-100% have artifacts (capped at 2 as proxy evidence)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
        USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TotalTables INT = 0;
        DECLARE @ValidatedTables INT = 0;

        WITH StagingTables AS (
            SELECT t.object_id
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name IN (''staging'', ''stage'', ''raw'', ''landing'', ''ods'', ''tmp'', ''temp'')
        )
        SELECT @TotalTables = COUNT(DISTINCT object_id) FROM StagingTables;

        IF @TotalTables > 0
        BEGIN
            SELECT @ValidatedTables = COUNT(DISTINCT t.object_id)
            FROM StagingTables t
            WHERE EXISTS (SELECT 1 FROM sys.check_constraints cc WHERE cc.parent_object_id = t.object_id)
               OR EXISTS (SELECT 1 FROM sys.computed_columns cc WHERE cc.object_id = t.object_id)
               OR EXISTS (SELECT 1 FROM sys.triggers tr WHERE tr.parent_id = t.object_id);
        END

        DECLARE @Pct FLOAT = CASE WHEN @TotalTables > 0 THEN (@ValidatedTables * 100.0) / @TotalTables ELSE 0 END;

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (@pDbName, CASE WHEN @TotalTables = 0 THEN 0 WHEN @Pct <= 25 THEN 1 ELSE 2 END);
        ';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(256)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;