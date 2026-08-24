-- Checklist: Integration tests validate end-to-end ETL
-- Scope: DATABASE
-- Scoring: 3 = at least one integration/end-to-end ETL test procedure found; 2 = reserved; 1 = ETL procedures exist but no integration test procedures found; 0 = no ETL-like procedures found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @EtlProcCount INT, @IntegrationTestProcCount INT;

    SELECT @EtlProcCount = COUNT(*) FROM sys.procedures
    WHERE name LIKE '%load%' OR name LIKE '%etl%' OR name LIKE '%pipeline%';

    SELECT @IntegrationTestProcCount = COUNT(*) FROM sys.procedures
    WHERE (name LIKE '%test%' OR name LIKE '%integration%')
      AND (name LIKE '%etl%' OR name LIKE '%load%' OR name LIKE '%pipeline%' OR name LIKE '%e2e%');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@EtlProcCount,0) = 0 THEN 0
             WHEN ISNULL(@IntegrationTestProcCount,0) > 0 THEN 3
             ELSE 1 END,
        CONCAT('ETL-like procedures = ', ISNULL(@EtlProcCount,0), ', integration/end-to-end ETL test procedures = ', ISNULL(@IntegrationTestProcCount,0))
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
            SET @Sql = N'DECLARE @ec INT, @ic INT;
SELECT @ec = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures
WHERE name LIKE ''%load%'' OR name LIKE ''%etl%'' OR name LIKE ''%pipeline%'';
SELECT @ic = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures
WHERE (name LIKE ''%test%'' OR name LIKE ''%integration%'')
  AND (name LIKE ''%etl%'' OR name LIKE ''%load%'' OR name LIKE ''%pipeline%'' OR name LIKE ''%e2e%'');
SELECT @p_Db,
       CASE WHEN ISNULL(@ec,0) = 0 THEN 0
            WHEN ISNULL(@ic,0) > 0 THEN 3
            ELSE 1 END,
       CONCAT(''ETL-like procedures = '', ISNULL(@ec,0), '', integration/end-to-end ETL test procedures = '', ISNULL(@ic,0));';

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