-- Checklist: Query Store used to force stable plans where regressions occur
-- Scope: DATABASE
-- Scoring: 0=Query Store disabled in any user DB; 1=Enabled in all DBs but no forced plans found; 2=Enabled in all DBs and forced plans exist; 3=Capped at 2 (proxy evidence; verifying regression resolution requires human judgment).
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @QSState INT = (SELECT actual_state FROM sys.database_query_store_options);
        DECLARE @ForcedCount INT = 0;
        IF @QSState IN (1, 2) -- 1=ReadWrite, 2=ReadOnly
        BEGIN
            SELECT @ForcedCount = COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1;
        END
        DECLARE @DbScore INT = 0;
        IF @QSState IN (1, 2)
        BEGIN
            IF @ForcedCount > 0 SET @DbScore = 2;
            ELSE SET @DbScore = 1;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
        END
        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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