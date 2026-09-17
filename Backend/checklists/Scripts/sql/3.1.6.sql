SET NOCOUNT ON;

-- Checklist 3.1.6 - Code is commented for complex logic; business rules explained
-- Read-only audit: inspects module definitions only, writes nothing outside tempdb.

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
CREATE TABLE #Databases
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#SkippedDatabases') IS NOT NULL DROP TABLE #SkippedDatabases;
CREATE TABLE #SkippedDatabases
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;
CREATE TABLE #ModuleStats
(
    DatabaseName     sysname       NOT NULL,
    ObjectName       nvarchar(600) NOT NULL,
    ObjectType       nvarchar(60)  NULL,
    DefinitionLength int           NOT NULL,
    IsComplex        bit           NOT NULL,
    HasComment       bit           NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Databases (DatabaseName)
    VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DatabaseName sysname;
DECLARE @Prefix nvarchar(300);
DECLARE @Sql nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Azure SQL Database has no cross-database access, so the current database is queried unqualified.
    SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DatabaseName) + N'.' END;

    SET @Sql = N'
        SELECT
            @DbNameParam,
            QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
            o.type_desc,
            CAST(LEN(m.definition) AS int),
            CASE WHEN LEN(m.definition) >= 1000
                       OR m.definition LIKE N''%WHILE %''
                       OR m.definition LIKE N''%CURSOR%''
                       OR m.definition LIKE N''%MERGE %''
                       OR m.definition LIKE N''%BEGIN TRY%''
                  THEN 1 ELSE 0 END,
            CASE WHEN m.definition LIKE N''%--%''
                       OR m.definition LIKE N''%/*%''
                  THEN 1 ELSE 0 END
        FROM ' + @Prefix + N'sys.sql_modules AS m
        INNER JOIN ' + @Prefix + N'sys.objects AS o
            ON o.object_id = m.object_id
        INNER JOIN ' + @Prefix + N'sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND m.definition IS NOT NULL
          AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'');';

    BEGIN TRY
        INSERT INTO #ModuleStats (DatabaseName, ObjectName, ObjectType, DefinitionLength, IsComplex, HasComment)
        EXEC sp_executesql @Sql, N'@DbNameParam sysname', @DbNameParam = @DatabaseName;
    END TRY
    BEGIN CATCH
        -- Database unreachable or definitions not visible to this login; recorded here so the open cursor is not disturbed.
        INSERT INTO #SkippedDatabases (DatabaseName)
        SELECT @DatabaseName
        WHERE NOT EXISTS (SELECT 1 FROM #SkippedDatabases AS s WHERE s.DatabaseName = @DatabaseName);
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @TotalModules int = (SELECT COUNT(*) FROM #ModuleStats);
DECLARE @TotalComplex int = (SELECT COUNT(*) FROM #ModuleStats WHERE IsComplex = 1);
DECLARE @CommentedComplex int = (SELECT COUNT(*) FROM #ModuleStats WHERE IsComplex = 1 AND HasComment = 1);
DECLARE @UncommentedComplex int = @TotalComplex - @CommentedComplex;
DECLARE @SkippedCount int = (SELECT COUNT(*) FROM #SkippedDatabases);
DECLARE @DbCount int =
(
    SELECT COUNT(*)
    FROM #Databases AS d
    WHERE NOT EXISTS (SELECT 1 FROM #SkippedDatabases AS s WHERE s.DatabaseName = d.DatabaseName)
);

DECLARE @CommentedPct decimal(5, 2) =
    CASE WHEN @TotalComplex = 0 THEN CAST(100.00 AS decimal(5, 2))
         ELSE CAST(100.0 * @CommentedComplex / @TotalComplex AS decimal(5, 2))
    END;

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #Databases AS d
                  WHERE NOT EXISTS (SELECT 1 FROM #SkippedDatabases AS s WHERE s.DatabaseName = d.DatabaseName)
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'N/A');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + x.DatabaseName + N'.' + x.ObjectName
                  FROM (SELECT TOP (5) ms.DatabaseName, ms.ObjectName, ms.DefinitionLength
                        FROM #ModuleStats AS ms
                        WHERE ms.IsComplex = 1 AND ms.HasComment = 0
                        ORDER BY ms.DefinitionLength DESC) AS x
                  ORDER BY x.DefinitionLength DESC
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @Finding nvarchar(max);

SET @Score =
    CASE WHEN @CommentedPct >= 90 THEN 3
         WHEN @CommentedPct >= 70 THEN 2
         WHEN @CommentedPct >= 40 THEN 1
         ELSE 0
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF @DbCount = 0
BEGIN
    SET @Finding = N'No accessible user databases could be inspected for T-SQL module comments (' + CAST(@SkippedCount AS nvarchar(10))
                 + N' database(s) were skipped because they were unreachable or their module definitions were not visible to this login).';
END
ELSE IF @TotalComplex = 0
BEGIN
    SET @Finding = N'Scanned ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s) and ' + CAST(@TotalModules AS nvarchar(10))
                 + N' user-defined module(s); none met the complexity threshold (definition >= 1000 characters or containing WHILE, CURSOR, MERGE or BEGIN TRY), so there is no complex logic requiring explanatory comments. Databases skipped for lack of access: '
                 + CAST(@SkippedCount AS nvarchar(10)) + N'.';
END
ELSE
BEGIN
    SET @Finding = N'Scanned ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s) and ' + CAST(@TotalModules AS nvarchar(10))
                 + N' user-defined module(s). ' + CAST(@TotalComplex AS nvarchar(10)) + N' module(s) qualify as complex; '
                 + CAST(@CommentedComplex AS nvarchar(10)) + N' contain inline comments (' + CAST(@CommentedPct AS nvarchar(10))
                 + N'%) and ' + CAST(@UncommentedComplex AS nvarchar(10)) + N' contain no comment at all. Largest uncommented complex module(s): '
                 + @Examples + N'. Databases skipped for lack of access: ' + CAST(@SkippedCount AS nvarchar(10))
                 + N'. Comment presence is a proxy; whether the comments actually explain the business rules requires manual code review.';
END

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;
IF OBJECT_ID('tempdb..#SkippedDatabases') IS NOT NULL DROP TABLE #SkippedDatabases;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;