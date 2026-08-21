/* Checklist 3.1.7 - No hardcoded literals for environment-specific values
   Scope : DATABASE (enumerates every qualifying user database itself)
   Access: read-only - catalog views only, no data or configuration is modified */
SET NOCOUNT ON;

DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Result          varchar(20);
DECLARE @Score           int = 0;
DECLARE @Finding         nvarchar(max) = N'No database found to be queried';

IF OBJECT_ID(N'tempdb..#Db')        IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID(N'tempdb..#Modules')   IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID(N'tempdb..#IpPattern') IS NOT NULL DROP TABLE #IpPattern;
IF OBJECT_ID(N'tempdb..#Findings')  IS NOT NULL DROP TABLE #Findings;

CREATE TABLE #Db
(
    DbName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #Modules
(
    DbName     sysname       NOT NULL,
    ObjectName nvarchar(600) NOT NULL,
    ObjectType nvarchar(60)  NOT NULL,
    Definition nvarchar(max) NULL
);

CREATE TABLE #IpPattern
(
    Pattern nvarchar(80) NOT NULL
);

CREATE TABLE #Findings
(
    DbName      sysname       NOT NULL,
    ObjectName  nvarchar(600) NOT NULL,
    LiteralType nvarchar(300) NOT NULL
);

/* Qualifying databases: online, accessible, non-system, not a snapshot.
   Azure SQL Database cannot switch context, so only the current database qualifies. */
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #Db (DbName)
    SELECT DB_NAME()
    WHERE DB_NAME() NOT IN (N'master', N'tempdb', N'model', N'msdb');
END
ELSE
BEGIN
    INSERT INTO #Db (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END;

IF NOT EXISTS (SELECT 1 FROM #Db)
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    DECLARE @Db  sysname;
    DECLARE @Sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DbName FROM #Db ORDER BY DbName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
            INSERT INTO #Modules (DbName, ObjectName, ObjectType, Definition)
            SELECT @DbName,
                   QUOTENAME(SCHEMA_NAME(o.schema_id)) + N''.'' + QUOTENAME(o.name),
                   o.type_desc,
                   m.definition
            FROM sys.sql_modules AS m
            INNER JOIN sys.objects AS o ON o.object_id = m.object_id
            WHERE o.is_ms_shipped = 0;';

        BEGIN TRY
            EXEC sp_executesql @Sql, N'@DbName sysname', @DbName = @Db;
        END TRY
        BEGIN CATCH
            /* database unreadable at this moment - skipped, remaining databases still audited */
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @Db;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    /* IPv4 shapes: 1-3 digits per octet, no wildcard gaps, to keep false positives low */
    ;WITH Digits AS
    (
        SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3
    )
    INSERT INTO #IpPattern (Pattern)
    SELECT N'%' + REPLICATE(N'[0-9]', a.n)
         + N'.'  + REPLICATE(N'[0-9]', b.n)
         + N'.'  + REPLICATE(N'[0-9]', c.n)
         + N'.'  + REPLICATE(N'[0-9]', d.n) + N'%'
    FROM Digits AS a
    CROSS JOIN Digits AS b
    CROSS JOIN Digits AS c
    CROSS JOIN Digits AS d;

    INSERT INTO #Findings (DbName, ObjectName, LiteralType)
    SELECT DISTINCT m.DbName, m.ObjectName, N'IP address literal'
    FROM #Modules AS m
    INNER JOIN #IpPattern AS p
            ON m.Definition LIKE p.Pattern;

    /* Path, URL, e-mail, distributed-query, connection-string and environment-token literals */
    INSERT INTO #Findings (DbName, ObjectName, LiteralType)
    SELECT m.DbName, m.ObjectName, v.LiteralType
    FROM #Modules AS m
    CROSS APPLY (VALUES
          (N'UNC network path literal',
           CASE WHEN m.Definition LIKE N'%\\%' THEN 1 ELSE 0 END)
        , (N'Local file-system path literal',
           CASE WHEN m.Definition LIKE N'%[A-Za-z]:\%' THEN 1 ELSE 0 END)
        , (N'URL literal',
           CASE WHEN m.Definition LIKE N'%http://%'
                  OR m.Definition LIKE N'%https://%'
                  OR m.Definition LIKE N'%ftp://%' THEN 1 ELSE 0 END)
        , (N'E-mail address literal',
           CASE WHEN m.Definition LIKE N'%@%.com%'
                  OR m.Definition LIKE N'%@%.net%'
                  OR m.Definition LIKE N'%@%.org%' THEN 1 ELSE 0 END)
        , (N'Connection-string fragment literal',
           CASE WHEN m.Definition LIKE N'%Data Source=%'
                  OR m.Definition LIKE N'%Initial Catalog=%'
                  OR m.Definition LIKE N'%Integrated Security=%' THEN 1 ELSE 0 END)
        , (N'Ad-hoc distributed query (OPENQUERY / OPENROWSET / OPENDATASOURCE)',
           CASE WHEN m.Definition LIKE N'%OPENQUERY%'
                  OR m.Definition LIKE N'%OPENROWSET%'
                  OR m.Definition LIKE N'%OPENDATASOURCE%' THEN 1 ELSE 0 END)
        , (N'Environment name token (PROD / DEV / TEST / UAT / QA)',
           CASE WHEN m.Definition LIKE N'%''PROD''%'
                  OR m.Definition LIKE N'%''PRODUCTION''%'
                  OR m.Definition LIKE N'%''DEV''%'
                  OR m.Definition LIKE N'%''TEST''%'
                  OR m.Definition LIKE N'%''UAT''%'
                  OR m.Definition LIKE N'%''QA''%' THEN 1 ELSE 0 END)
    ) AS v (LiteralType, IsHit)
    WHERE v.IsHit = 1;

    /* Hardcoded linked server names - sys.servers is not available on Azure SQL Database */
    IF SERVERPROPERTY('EngineEdition') <> 5
    BEGIN
        EXEC sp_executesql N'
            INSERT INTO #Findings (DbName, ObjectName, LiteralType)
            SELECT DISTINCT m.DbName, m.ObjectName,
                   N''Hardcoded linked server name ('' + s.name + N'')''
            FROM #Modules AS m
            INNER JOIN sys.servers AS s
                    ON s.server_id > 0
                   AND LEN(s.name) >= 3
                   AND m.Definition LIKE N''%''
                                      + REPLACE(REPLACE(REPLACE(s.name, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'')
                                      + N''%'';';
    END;

    /* Hardcoded three-part references to a different user database on this instance */
    INSERT INTO #Findings (DbName, ObjectName, LiteralType)
    SELECT DISTINCT m.DbName, m.ObjectName,
           N'Hardcoded cross-database reference (' + d.name + N')'
    FROM #Modules AS m
    INNER JOIN sys.databases AS d
            ON d.database_id > 4
           AND d.name <> m.DbName
           AND m.Definition LIKE N'%'
                              + REPLACE(REPLACE(REPLACE(d.name, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]')
                              + N'.%.%';

    SET @DatabaseQueried = ISNULL(STUFF((SELECT N', ' + b.DbName
                                         FROM #Db AS b
                                         ORDER BY b.DbName
                                         FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

    DECLARE @DbCount         int = (SELECT COUNT(*) FROM #Db);
    DECLARE @TotalModules    int = (SELECT COUNT(*) FROM #Modules);
    DECLARE @AffectedModules int = (SELECT COUNT(*) FROM (SELECT DISTINCT DbName, ObjectName FROM #Findings) AS a);
    DECLARE @Pct decimal(5,2) =
            CASE WHEN (SELECT COUNT(*) FROM #Modules) = 0 THEN CAST(0 AS decimal(5,2))
                 ELSE CAST((SELECT COUNT(*) FROM (SELECT DISTINCT DbName, ObjectName FROM #Findings) AS b) * 100.0
                           / (SELECT COUNT(*) FROM #Modules) AS decimal(5,2))
            END;

    DECLARE @Sample nvarchar(max) =
            STUFF((SELECT N'; ' + x.DbName + N'.' + x.ObjectName + N' -> ' + x.LiteralType
                   FROM (SELECT DISTINCT TOP (10) DbName, ObjectName, LiteralType
                         FROM #Findings
                         ORDER BY DbName, ObjectName, LiteralType) AS x
                   ORDER BY x.DbName, x.ObjectName, x.LiteralType
                   FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @TotalModules = 0
    BEGIN
        SELECT @Score   = 3,
               @Finding = N'The ' + CAST(@DbCount AS nvarchar(20)) + N' qualifying user database(s) contain no user-defined '
                        + N'T-SQL modules (procedures, functions, views or triggers), so no hardcoded environment-specific literals exist.';
    END
    ELSE IF @AffectedModules = 0
    BEGIN
        SELECT @Score   = 3,
               @Finding = N'All ' + CAST(@TotalModules AS nvarchar(20)) + N' user-defined T-SQL module(s) across '
                        + CAST(@DbCount AS nvarchar(20)) + N' user database(s) were scanned; none contains an IP address, '
                        + N'UNC or local path, URL, e-mail address, connection-string fragment, ad-hoc distributed query, '
                        + N'environment name token, linked server name or hardcoded cross-database three-part reference.';
    END
    ELSE IF @Pct <= CAST(10.00 AS decimal(5,2))
    BEGIN
        SELECT @Score   = 2,
               @Finding = CAST(@AffectedModules AS nvarchar(20)) + N' of ' + CAST(@TotalModules AS nvarchar(20))
                        + N' user-defined T-SQL module(s) across ' + CAST(@DbCount AS nvarchar(20)) + N' user database(s) ('
                        + CAST(@Pct AS nvarchar(20)) + N'%) contain environment-specific literals. Isolated occurrences: '
                        + ISNULL(@Sample, N'(none listed)') + N'.';
    END
    ELSE
    BEGIN
        SELECT @Score   = 1,
               @Finding = CAST(@AffectedModules AS nvarchar(20)) + N' of ' + CAST(@TotalModules AS nvarchar(20))
                        + N' user-defined T-SQL module(s) across ' + CAST(@DbCount AS nvarchar(20)) + N' user database(s) ('
                        + CAST(@Pct AS nvarchar(20)) + N'%) contain environment-specific literals, so the code base is bound '
                        + N'to a single environment. Examples: ' + ISNULL(@Sample, N'(none listed)') + N'.';
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;