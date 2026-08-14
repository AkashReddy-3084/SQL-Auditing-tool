-- Checklist: Key lookups minimized via covering indexes where beneficial
-- Scope: DATABASE
-- Scoring: 0 = High Key Lookups in cache or significant missing index impact; 1 = Moderate Key Lookups or some missing index gaps; 2 = Few Key Lookups with minor missing index impact; 3 = No Key Lookups in cached plans and no missing index recommendations.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET NOCOUNT ON;
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
        DECLARE @LC INT = 0;
        DECLARE @MI FLOAT = 0;

        SELECT @LC = COUNT(DISTINCT qs.plan_handle)
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
        WHERE qs.database_id = DB_ID()
          AND CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE ''%Key Lookup%'';

        SELECT @MI = ISNULL(SUM(avg_total_user_cost * avg_user_impact * (user_seeks + user_scans)), 0)
        FROM sys.dm_db_missing_index_group_stats migs
        INNER JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
        INNER JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
        WHERE mid.database_id = DB_ID();

        INSERT INTO #DbResults VALUES (DB_NAME(), CASE
            WHEN @LC = 0 AND @MI = 0 THEN 3
            WHEN @LC <= 5 AND @MI < 1000 THEN 2
            WHEN @LC <= 20 AND @MI < 10000 THEN 1
            ELSE 0
        END);
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
SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;