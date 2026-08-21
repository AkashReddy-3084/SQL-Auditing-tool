SET NOCOUNT ON;

/* Checklist 3.1.2 - No SELECT * in production code; explicit column lists.
   Read-only: writes only to temp tables. */

IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;
IF OBJECT_ID('tempdb..#ModuleScan') IS NOT NULL DROP TABLE #ModuleScan;

CREATE TABLE #ScannedDb
(
    DatabaseName sysname       NOT NULL PRIMARY KEY,
    Prefix       nvarchar(300) NOT NULL,
    Scanned      bit           NOT NULL,
    ErrorText    nvarchar(400) NULL
);

CREATE TABLE #ModuleScan
(
    DatabaseName  sysname      NOT NULL,
    SchemaName    sysname      NOT NULL,
    ObjectName    sysname      NOT NULL,
    ObjectType    nvarchar(60) NULL,
    HasSelectStar bit          NULL   -- NULL = definition not readable (no VIEW DEFINITION)
);

IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5
BEGIN
    /* Azure SQL Database: cross-database queries are not possible, scan the current database only. */
    INSERT INTO #ScannedDb (DatabaseName, Prefix, Scanned, ErrorText)
    VALUES (DB_NAME(), N'', 0, NULL);
END
ELSE
BEGIN
    INSERT INTO #ScannedDb (DatabaseName, Prefix, Scanned, ErrorText)
    SELECT d.name, QUOTENAME(d.name) + N'.', 0, NULL
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db     sysname,
        @prefix nvarchar(300),
        @sql    nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, Prefix FROM #ScannedDb ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db, @prefix;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
        SELECT @p_db,
               s.name,
               o.name,
               o.type_desc,
               CASE
                   WHEN m.definition IS NULL THEN NULL
                   WHEN REPLACE(REPLACE(
                            UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                                m.definition,
                                CHAR(13), N'' ''), CHAR(10), N'' ''), CHAR(9), N'' ''),
                                N''  '', N'' ''), N''  '', N'' ''), N''  '', N'' '')),
                            N''EXISTS (SELECT *'', N''''), N''EXISTS(SELECT *'', N'''')
                        LIKE N''%SELECT *%''
                        THEN 1
                   ELSE 0
               END
        FROM ' + @prefix + N'sys.sql_modules AS m
        INNER JOIN ' + @prefix + N'sys.objects AS o ON o.object_id = m.object_id
        INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'', ''TR'');';

        INSERT INTO #ModuleScan (DatabaseName, SchemaName, ObjectName, ObjectType, HasSelectStar)
        EXEC sp_executesql @sql, N'@p_db sysname', @p_db = @db;

        UPDATE #ScannedDb SET Scanned = 1 WHERE DatabaseName = @db;
    END TRY
    BEGIN CATCH
        UPDATE #ScannedDb
        SET Scanned   = 0,
            ErrorText = LEFT(ERROR_MESSAGE(), 400)
        WHERE DatabaseName = @db;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db, @prefix;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @TotalDbs      int = (SELECT COUNT(*) FROM #ScannedDb),
        @ScannedDbs    int = (SELECT COUNT(*) FROM #ScannedDb WHERE Scanned = 1),
        @TotalModules  int = (SELECT COUNT(*) FROM #ModuleScan),
        @Readable      int = (SELECT COUNT(*) FROM #ModuleScan WHERE HasSelectStar IS NOT NULL),
        @Violations    int = (SELECT COUNT(*) FROM #ModuleScan WHERE HasSelectStar = 1),
        @ViolatingDbs  int = (SELECT COUNT(DISTINCT DatabaseName) FROM #ModuleScan WHERE HasSelectStar = 1);

DECLARE @Pct decimal(9,2) =
    CASE WHEN @Readable > 0
         THEN CAST(@Violations AS decimal(18,4)) * 100.0 / CAST(@Readable AS decimal(18,4))
         ELSE 0 END;

DECLARE @DbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #ScannedDb AS d
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N', ' + t.DatabaseName + N'.' + t.SchemaName + N'.' + t.ObjectName
                  FROM #ModuleScan AS t
                  WHERE t.HasSelectStar = 1
                  ORDER BY t.DatabaseName, t.SchemaName, t.ObjectName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @FailedDbs nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #ScannedDb AS d
                  WHERE d.Scanned = 0
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @Result  nvarchar(30),
        @Score   int,
        @Finding nvarchar(max);

IF @TotalDbs = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No accessible online user database was found on this instance, so production T-SQL code could not be inspected for SELECT * usage. Verify database visibility and connection permissions, then re-run.';
END
ELSE IF @TotalModules > 0 AND @Readable = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'Found ' + CAST(@TotalModules AS nvarchar(20)) + N' programmable module(s) across ' + CAST(@ScannedDbs AS nvarchar(20))
                 + N' database(s), but no module definition was readable (VIEW DEFINITION permission is missing), so SELECT * usage could not be determined.';
END
ELSE IF @TotalModules = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'No user-defined programmable modules (stored procedures, views, functions, triggers) exist in the ' + CAST(@ScannedDbs AS nvarchar(20))
                 + N' scanned database(s), so no SELECT * usage is present in server-side production code.';
END
ELSE IF @Violations = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CAST(@Readable AS nvarchar(20)) + N' readable programmable module(s) across ' + CAST(@ScannedDbs AS nvarchar(20))
                 + N' database(s) use explicit column lists; 0 modules contain SELECT * (the EXISTS (SELECT *) idiom is excluded from the count).';
END
ELSE IF @Pct <= 5.0
BEGIN
    SET @Score  = 2;
    SET @Finding = CAST(@Violations AS nvarchar(20)) + N' of ' + CAST(@Readable AS nvarchar(20)) + N' readable module(s) ('
                 + CAST(@Pct AS nvarchar(20)) + N'%) across ' + CAST(@ViolatingDbs AS nvarchar(20)) + N' database(s) still use SELECT *. Examples: ' + @Examples + N'.';
END
ELSE IF @Pct <= 20.0
BEGIN
    SET @Score  = 1;
    SET @Finding = CAST(@Violations AS nvarchar(20)) + N' of ' + CAST(@Readable AS nvarchar(20)) + N' readable module(s) ('
                 + CAST(@Pct AS nvarchar(20)) + N'%) across ' + CAST(@ViolatingDbs AS nvarchar(20)) + N' database(s) still use SELECT *. Examples: ' + @Examples + N'.';
END
ELSE
BEGIN
    SET @Score  = 0;
    SET @Finding = CAST(@Violations AS nvarchar(20)) + N' of ' + CAST(@Readable AS nvarchar(20)) + N' readable module(s) ('
                 + CAST(@Pct AS nvarchar(20)) + N'%) across ' + CAST(@ViolatingDbs AS nvarchar(20)) + N' database(s) use SELECT * instead of explicit column lists. Examples: ' + @Examples + N'.';
END

IF @TotalModules > 0 AND @Readable > 0 AND @Readable < @TotalModules
    SET @Finding = @Finding + N' Note: ' + CAST(@TotalModules - @Readable AS nvarchar(20)) + N' module definition(s) were not readable (VIEW DEFINITION permission missing) and are excluded from the ratio.';

IF LEN(@FailedDbs) > 0
    SET @Finding = @Finding + N' Database(s) that could not be scanned: ' + @FailedDbs + N'.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                       AS Result,
    @Score                        AS Score,
    LEFT(@DbList, 4000)           AS DatabaseQueried,
    LEFT(@Finding, 4000)          AS Finding;

DROP TABLE #ModuleScan;
DROP TABLE #ScannedDb;