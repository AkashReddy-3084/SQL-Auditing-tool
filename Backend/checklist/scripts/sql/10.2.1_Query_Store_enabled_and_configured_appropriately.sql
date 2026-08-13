-- Checklist: Query Store enabled and configured appropriately
-- Scope: DATABASE
-- Scoring: 0=Disabled in any DB; 1=Enabled but read-only or suboptimal (storage<1GB or flush>20min); 2=Enabled read_write with reasonable settings (storage>=1GB, flush<=20min); 3=Enabled read_write with optimal settings (storage>=10GB, flush<=10min, auto capture, size-based cleanup on)
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
        DECLARE @s INT = 0;
        IF OBJECT_ID(''sys.database_query_store_options'') IS NOT NULL
        BEGIN
            SELECT @s = CASE
                WHEN actual_state = 0 THEN 0
                WHEN actual_state = 1 THEN 1
                WHEN actual_state = 2 THEN
                    CASE
                        WHEN max_storage_size_mb >= 10240 AND data_flush_interval_seconds <= 600 AND query_capture_mode = 1 AND size_based_cleanup_mode = 1 THEN 3
                        WHEN max_storage_size_mb >= 1024 AND data_flush_interval_seconds <= 1200 AND query_capture_mode IN (1,2,3) THEN 2
                        ELSE 1
                    END
                ELSE 0
            END
            FROM sys.database_query_store_options;
        END
        INSERT INTO #DbResults VALUES (@DbNameParam, @s);';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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