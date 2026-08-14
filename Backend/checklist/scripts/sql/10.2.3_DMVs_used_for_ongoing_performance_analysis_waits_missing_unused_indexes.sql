-- Checklist: DMVs used for ongoing performance analysis (waits, missing/unused indexes)
-- Scope: DATABASE
-- Scoring: 3=DMVs accessible & populated (missing/unused indexes found); 2=Accessible but empty; 1=Partial access/permissions; 0=Inaccessible or no evidence
-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET NOCOUNT ON;
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
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @MissingIdx INT = 0;
        DECLARE @UnusedIdx INT = 0;
        SELECT @MissingIdx = COUNT(*) FROM sys.dm_db_missing_index_details;
        SELECT @UnusedIdx = COUNT(*) FROM sys.dm_db_index_usage_stats
        WHERE user_seeks = 0 AND user_scans = 0 AND user_lookups = 0 AND user_updates > 0;
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', CASE
            WHEN @MissingIdx > 0 OR @UnusedIdx > 0 THEN 3
            ELSE 2
        END);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 1);
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