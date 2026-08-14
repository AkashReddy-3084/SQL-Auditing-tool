-- Checklist: Missing indexes reviewed and applied judiciously
-- Scope: DATABASE
-- Scoring: 0=High impact missing indexes (>1000 avg impact or >10 indexes), 1=Moderate impact (100-1000 avg or 3-10 indexes), 2=Low impact (<100 avg or 0-2 indexes), 3=Fully compliant (capped at 2 due to proxy evidence requiring human judgment)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @DbId INT;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT database_id, name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbId, @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
        DECLARE @Impact FLOAT = 0;
        DECLARE @Count INT = 0;
        SELECT @Impact = ISNULL(AVG(avg_total_user_impact), 0), @Count = COUNT(DISTINCT mig.index_handle)
        FROM sys.dm_db_missing_index_group_stats migss
        JOIN sys.dm_db_missing_index_groups mig ON migss.group_handle = mig.group_handle
        JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
        WHERE mid.database_id = ' + CAST(@DbId AS NVARCHAR(10)) + N';

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (' + QUOTENAME(@DbName, '''') + ', 
            CASE 
                WHEN @Count = 0 THEN 2
                WHEN @Impact > 1000 OR @Count > 10 THEN 0
                WHEN @Impact >= 100 OR @Count >= 3 THEN 1
                ELSE 2
            END
        );';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbId, @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
IF @Score > 2 SET @Score = 2;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;