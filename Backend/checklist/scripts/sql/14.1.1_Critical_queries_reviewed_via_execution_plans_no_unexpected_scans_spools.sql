-- Checklist: Critical queries reviewed via execution plans (no unexpected scans/spools)
-- Scope: DATABASE
-- Scoring: 3=Fully compliant (not achievable via proxy); 2=No high-cost queries with scans/spills found; 1=Few (<5) problematic plans found; 0=Many (>5) problematic plans found
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
        DECLARE @IssueCount INT = 0;
        SELECT @IssueCount = COUNT(*) FROM (
            SELECT TOP 1000 qs.plan_handle
            FROM sys.dm_exec_query_stats qs
            CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
            WHERE qs.database_id = DB_ID()
              AND qs.total_worker_time > 1000000
              AND qp.query_plan IS NOT NULL
              AND qp.query_plan.exist(''//RelOp[@PhysicalOp="Index Scan" or @PhysicalOp="Clustered Index Scan" or @PhysicalOp="Table Scan" or @PhysicalOp="SpillToTempDb" or @PhysicalOp="Spool"]'') = 1
            ORDER BY qs.total_worker_time DESC
        ) AS Issues;

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', CASE
            WHEN @IssueCount = 0 THEN 2
            WHEN @IssueCount < 5 THEN 1
            ELSE 0
        END);';
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