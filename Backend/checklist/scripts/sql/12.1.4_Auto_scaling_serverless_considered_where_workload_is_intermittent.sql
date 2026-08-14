-- Checklist: Auto-scaling / serverless considered where workload is intermittent
-- Scope: DATABASE
-- Scoring: 0 = No serverless/auto-scaling configured; 1 = Provisioned tier without auto-scaling or on-prem fallback; 2 = Serverless or Auto-Pause configured; 3 = Fully verified compliance (capped at 2 as workload intermittency requires human review)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DbScore = 0;
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        IF OBJECT_ID(''sys.database_service_objectives'') IS NOT NULL
        BEGIN
            SELECT @DbScore = CASE 
                WHEN EXISTS (SELECT 1 FROM sys.database_service_objectives WHERE edition = ''Serverless'' OR ISNULL(auto_pause_delay_seconds, 0) > 0) THEN 2
                ELSE 1
            END;
        END
        ELSE
        BEGIN
            SET @DbScore = 1;
        END';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
    END TRY
    BEGIN CATCH
        SET @DbScore = 0;
    END CATCH;
    
    INSERT INTO #DbResults VALUES (@DbName, @DbScore);
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.