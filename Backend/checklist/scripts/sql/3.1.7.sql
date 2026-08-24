-- Checklist: No hardcoded literals for environment-specific values
-- Scope: DATABASE
-- Scoring: 3 = 0% of modules show hardcoded environment-specific evidence; 2 = under 10%; 1 = 10-49%; 0 = no modules found, or 50%+
-- NOTE: Automated evidence only; text-pattern matching is a proxy for hardcoded environment values. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @ModuleCount INT, @HardcodedModuleCount INT;

    SELECT @ModuleCount = COUNT(*) FROM sys.sql_modules;

    SELECT @HardcodedModuleCount = COUNT(*) FROM sys.sql_modules
    WHERE definition LIKE '%''PROD''%' OR definition LIKE '%''DEV''%' OR definition LIKE '%''TEST''%' OR definition LIKE '%''UAT''%'
       OR definition LIKE '%\\%\%' OR definition LIKE '%C:\%' OR definition LIKE '%D:\%';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@ModuleCount,0) = 0 THEN 0
             WHEN ISNULL(@HardcodedModuleCount,0) = 0 THEN 3
             WHEN (CAST(ISNULL(@HardcodedModuleCount,0) AS DECIMAL(9,4)) / NULLIF(@ModuleCount,0)) < 0.10 THEN 2
             WHEN (CAST(ISNULL(@HardcodedModuleCount,0) AS DECIMAL(9,4)) / NULLIF(@ModuleCount,0)) < 0.50 THEN 1
             ELSE 0 END,
        CONCAT('Modules total = ', ISNULL(@ModuleCount,0), ', with hardcoded environment evidence = ', ISNULL(@HardcodedModuleCount,0))
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
            SET @Sql = N'DECLARE @mc INT, @hc INT;
SELECT @mc = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules;
SELECT @hc = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules
WHERE definition LIKE ''%''''PROD''''%'' OR definition LIKE ''%''''DEV''''%'' OR definition LIKE ''%''''TEST''''%'' OR definition LIKE ''%''''UAT''''%''
   OR definition LIKE ''%\\%'' OR definition LIKE ''%C:\%'' OR definition LIKE ''%D:\%'';
SELECT @p_Db,
       CASE WHEN ISNULL(@mc,0) = 0 THEN 0
            WHEN ISNULL(@hc,0) = 0 THEN 3
            WHEN (CAST(ISNULL(@hc,0) AS DECIMAL(9,4)) / NULLIF(@mc,0)) < 0.10 THEN 2
            WHEN (CAST(ISNULL(@hc,0) AS DECIMAL(9,4)) / NULLIF(@mc,0)) < 0.50 THEN 1
            ELSE 0 END,
       CONCAT(''Modules total = '', ISNULL(@mc,0), '', with hardcoded environment evidence = '', ISNULL(@hc,0));';

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