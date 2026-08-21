SET NOCOUNT ON;

/* Checklist 3.2.5 - Dynamic SQL, where used, is parameterized (sp_executesql) - no injection risk */
/* Read-only: writes only to session temp tables. */

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;
CREATE TABLE #TargetDatabases
(
    DatabaseName sysname NOT NULL
);

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
CREATE TABLE #Modules
(
    DatabaseName sysname        NOT NULL,
    SchemaName   sysname        NOT NULL,
    ObjectName   sysname        NOT NULL,
    ObjectType   nvarchar(60)   NULL,
    Definition   nvarchar(max)  NULL
);

IF OBJECT_ID('tempdb..#Classified') IS NOT NULL DROP TABLE #Classified;
CREATE TABLE #Classified
(
    DatabaseName     sysname      NOT NULL,
    SchemaName       sysname      NOT NULL,
    ObjectName       sysname      NOT NULL,
    ObjectType       nvarchar(60) NULL,
    UsesExecString   bit          NOT NULL,
    UsesSpExecuteSql bit          NOT NULL
);

/* ---------- 1. Determine which databases to inspect ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #TargetDatabases (DatabaseName)
    SELECT ISNULL(DB_NAME(), N'Unknown');
END
ELSE
BEGIN
    INSERT INTO #TargetDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb',
                         N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution')
      AND d.state = 0
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = N'READ_WRITE';
END

DECLARE @DbCount    int = ISNULL((SELECT COUNT(*) FROM #TargetDatabases), 0);
DECLARE @SkippedDbs int = 0;

/* ---------- 2. Collect candidate module definitions from each database ---------- */
DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #TargetDatabases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @DbNameParam AS DatabaseName,
       s.name        AS SchemaName,
       o.name        AS ObjectName,
       o.type_desc   AS ObjectType,
       m.definition  AS Definition
FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
        ON o.object_id = m.object_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND s.name <> N''sys''
  AND m.definition IS NOT NULL
  AND m.definition COLLATE Latin1_General_CI_AS LIKE N''%exec%'';';

        INSERT INTO #Modules (DatabaseName, SchemaName, ObjectName, ObjectType, Definition)
        EXEC sp_executesql @Sql, N'@DbNameParam sysname', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        SET @SkippedDbs = @SkippedDbs + 1;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---------- 3. Classify each module ---------- */
INSERT INTO #Classified (DatabaseName, SchemaName, ObjectName, ObjectType, UsesExecString, UsesSpExecuteSql)
SELECT m.DatabaseName,
       m.SchemaName,
       m.ObjectName,
       m.ObjectType,
       CASE WHEN m.Definition COLLATE Latin1_General_CI_AS LIKE N'%exec(%'
              OR m.Definition COLLATE Latin1_General_CI_AS LIKE N'%exec (%'
              OR m.Definition COLLATE Latin1_General_CI_AS LIKE N'%execute(%'
              OR m.Definition COLLATE Latin1_General_CI_AS LIKE N'%execute (%'
            THEN 1 ELSE 0 END AS UsesExecString,
       CASE WHEN m.Definition COLLATE Latin1_General_CI_AS LIKE N'%sp_executesql%'
            THEN 1 ELSE 0 END AS UsesSpExecuteSql
FROM #Modules AS m;

DECLARE @DynamicModules int =
    ISNULL((SELECT COUNT(*) FROM #Classified WHERE UsesExecString = 1 OR UsesSpExecuteSql = 1), 0);
DECLARE @UnsafeModules int =
    ISNULL((SELECT COUNT(*) FROM #Classified WHERE UsesExecString = 1), 0);
DECLARE @SafeModules int =
    ISNULL((SELECT COUNT(*) FROM #Classified WHERE UsesExecString = 0 AND UsesSpExecuteSql = 1), 0);
DECLARE @UnsafeDbCount int =
    ISNULL((SELECT COUNT(DISTINCT DatabaseName) FROM #Classified WHERE UsesExecString = 1), 0);

/* ---------- 4. Build evidence strings ---------- */
DECLARE @DbList nvarchar(max);

IF @DbCount = 0
    SET @DbList = N'None';
ELSE IF @DbCount <= 10
    SET @DbList = ISNULL(STUFF(ISNULL((SELECT N', ' + t.DatabaseName
                                       FROM #TargetDatabases AS t
                                       ORDER BY t.DatabaseName
                                       FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), N''), 1, 2, N''), N'None');
ELSE
    SET @DbList = CAST(@DbCount AS nvarchar(20)) + N' user databases';

SET @DbList = ISNULL(NULLIF(@DbList, N''), N'None');

DECLARE @Examples nvarchar(max) = N'';

SELECT @Examples = @Examples + N'; ' + x.FullName
FROM (SELECT TOP (5)
             c.DatabaseName + N'.' + c.SchemaName + N'.' + c.ObjectName AS FullName
      FROM #Classified AS c
      WHERE c.UsesExecString = 1
      ORDER BY c.DatabaseName, c.SchemaName, c.ObjectName) AS x;

SET @Examples = ISNULL(@Examples, N'');

IF LEN(@Examples) > 2
    SET @Examples = ISNULL(STUFF(@Examples, 1, 2, N''), N'');
ELSE
    SET @Examples = N'';

SET @Examples = ISNULL(NULLIF(@Examples, N''), N'n/a');

/* ---------- 5. Score ---------- */
DECLARE @Result  nvarchar(30);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @DbCount = 0 OR @SkippedDbs = @DbCount
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No accessible user database could be inspected (databases enumerated: '
                 + CAST(@DbCount AS nvarchar(20)) + N', unreadable: ' + CAST(@SkippedDbs AS nvarchar(20))
                 + N'). Dynamic SQL parameterisation could not be evidenced and requires manual review.';
END
ELSE IF @DynamicModules = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No dynamic SQL detected. Across ' + CAST(@DbCount AS nvarchar(20))
                 + N' user database(s), no non-system module uses EXEC()/EXECUTE() string execution or sp_executesql, so there is no injection surface from dynamic SQL.';
END
ELSE IF @UnsafeModules = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All dynamic SQL is parameterised. ' + CAST(@SafeModules AS nvarchar(20))
                 + N' of ' + CAST(@DynamicModules AS nvarchar(20))
                 + N' dynamic-SQL module(s) across ' + CAST(@DbCount AS nvarchar(20))
                 + N' user database(s) execute through sp_executesql and none use the non-parameterisable EXEC()/EXECUTE() string form.';
END
ELSE IF (@UnsafeModules * 10) <= @DynamicModules
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Mostly parameterised, with exceptions. ' + CAST(@UnsafeModules AS nvarchar(20))
                 + N' of ' + CAST(@DynamicModules AS nvarchar(20))
                 + N' dynamic-SQL module(s) in ' + CAST(@UnsafeDbCount AS nvarchar(20))
                 + N' database(s) use EXEC()/EXECUTE() string execution, which cannot be parameterised; '
                 + CAST(@SafeModules AS nvarchar(20)) + N' module(s) correctly use sp_executesql. Examples: '
                 + @Examples + N'.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Non-parameterised dynamic SQL is prevalent. ' + CAST(@UnsafeModules AS nvarchar(20))
                 + N' of ' + CAST(@DynamicModules AS nvarchar(20))
                 + N' dynamic-SQL module(s) in ' + CAST(@UnsafeDbCount AS nvarchar(20))
                 + N' database(s) execute concatenated statements via EXEC()/EXECUTE() instead of sp_executesql, exposing an injection risk; only '
                 + CAST(@SafeModules AS nvarchar(20)) + N' module(s) use sp_executesql. Examples: '
                 + @Examples + N'.';
END

IF @SkippedDbs > 0 AND @Score > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@SkippedDbs AS nvarchar(20))
                 + N' database(s) could not be read and were excluded.';

SET @Score   = ISNULL(@Score, 0);
SET @Finding = ISNULL(NULLIF(@Finding, N''), N'Dynamic SQL parameterisation could not be determined.');
SET @Result  = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* ---------- 6. Output ---------- */
SELECT @Result  AS Result,
       @Score   AS Score,
       @DbList  AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#Classified') IS NOT NULL DROP TABLE #Classified;
IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;