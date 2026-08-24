-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 3 = 90%+ of table-referencing modules show schema-qualified references; 2 = 50-89%; 1 = under 50%; 0 = no table-referencing modules found
-- NOTE: Automated evidence only; text-based detection is a proxy and may undercount schema qualification styles other than dbo. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @ReferencingModules INT, @QualifiedModules INT;

    SELECT @ReferencingModules = COUNT(*) FROM sys.sql_modules WHERE definition LIKE '%FROM %' OR definition LIKE '%JOIN %';
    SELECT @QualifiedModules = COUNT(*) FROM sys.sql_modules
    WHERE (definition LIKE '%FROM %' OR definition LIKE '%JOIN %')
      AND (definition LIKE '%FROM dbo.%' OR definition LIKE '%JOIN dbo.%' OR definition LIKE '%FROM [dbo].%' OR definition LIKE '%JOIN [dbo].%');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@ReferencingModules,0) = 0 THEN 0
             WHEN (CAST(ISNULL(@QualifiedModules,0) AS DECIMAL(9,4)) / NULLIF(@ReferencingModules,0)) >= 0.90 THEN 3
             WHEN (CAST(ISNULL(@QualifiedModules,0) AS DECIMAL(9,4)) / NULLIF(@ReferencingModules,0)) >= 0.50 THEN 2
             ELSE 1 END,
        CONCAT('Table-referencing modules = ', ISNULL(@ReferencingModules,0), ', with schema-qualified reference = ', ISNULL(@QualifiedModules,0))
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
            SET @Sql = N'DECLARE @rm INT, @qm INT;
SELECT @rm = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules WHERE definition LIKE ''%FROM %'' OR definition LIKE ''%JOIN %'';
SELECT @qm = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules
WHERE (definition LIKE ''%FROM %'' OR definition LIKE ''%JOIN %'')
  AND (definition LIKE ''%FROM dbo.%'' OR definition LIKE ''%JOIN dbo.%'' OR definition LIKE ''%FROM [dbo].%'' OR definition LIKE ''%JOIN [dbo].%'');
SELECT @p_Db,
       CASE WHEN ISNULL(@rm,0) = 0 THEN 0
            WHEN (CAST(ISNULL(@qm,0) AS DECIMAL(9,4)) / NULLIF(@rm,0)) >= 0.90 THEN 3
            WHEN (CAST(ISNULL(@qm,0) AS DECIMAL(9,4)) / NULLIF(@rm,0)) >= 0.50 THEN 2
            ELSE 1 END,
       CONCAT(''Table-referencing modules = '', ISNULL(@rm,0), '', with schema-qualified reference = '', ISNULL(@qm,0));';

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