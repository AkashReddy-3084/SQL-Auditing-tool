-- Checklist: Load completion SLAs set and monitored
-- Scope: DATABASE
-- Scoring: 3 = 10%+ of ETL/load procedures show a load-duration-monitoring pattern (DATEDIFF + logging/RAISERROR); 2 = under 10% do; 1 = ETL procedures exist but none do; 0 = no ETL/load procedures found
-- NOTE: Automated evidence only; the specific SLA time target value is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @EtlProcCount INT, @MonitoredProcCount INT;

    SELECT @EtlProcCount = COUNT(*) FROM sys.procedures
    WHERE name LIKE '%load%' OR name LIKE '%etl%';

    SELECT @MonitoredProcCount = COUNT(DISTINCT p.object_id)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON m.object_id = p.object_id
    WHERE (p.name LIKE '%load%' OR p.name LIKE '%etl%')
      AND m.definition LIKE '%DATEDIFF(%'
      AND (m.definition LIKE '%INSERT %' OR m.definition LIKE '%RAISERROR%' OR m.definition LIKE '%THROW%');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@EtlProcCount,0) = 0 THEN 0
             WHEN (CAST(ISNULL(@MonitoredProcCount,0) AS DECIMAL(9,4)) / NULLIF(@EtlProcCount,0)) >= 0.10 THEN 3
             WHEN ISNULL(@MonitoredProcCount,0) > 0 THEN 2
             ELSE 1 END,
        CONCAT('ETL/load procedures = ', ISNULL(@EtlProcCount,0), ', with a load-duration-monitoring pattern = ', ISNULL(@MonitoredProcCount,0))
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @ec INT, @mc INT;
SELECT @ec = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures
WHERE name LIKE ''%load%'' OR name LIKE ''%etl%'';
SELECT @mc = COUNT(DISTINCT p.object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON m.object_id = p.object_id
WHERE (p.name LIKE ''%load%'' OR p.name LIKE ''%etl%'')
  AND m.definition LIKE ''%DATEDIFF(%''
  AND (m.definition LIKE ''%INSERT %'' OR m.definition LIKE ''%RAISERROR%'' OR m.definition LIKE ''%THROW%'');
SELECT @p_Db,
       CASE WHEN ISNULL(@ec,0) = 0 THEN 0
            WHEN (CAST(ISNULL(@mc,0) AS DECIMAL(9,4)) / NULLIF(@ec,0)) >= 0.10 THEN 3
            WHEN ISNULL(@mc,0) > 0 THEN 2
            ELSE 1 END,
       CONCAT(''ETL/load procedures = '', ISNULL(@ec,0), '', with a load-duration-monitoring pattern = '', ISNULL(@mc,0));';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;