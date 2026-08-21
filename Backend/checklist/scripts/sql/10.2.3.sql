/* Checklist 10.2.3 - DMVs used for ongoing performance analysis (waits, missing/unused indexes)
   Read-only. Detects persisted artifacts that consume the relevant performance DMVs. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureDb BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
DECLARE @ScanErrors INT = 0;
DECLARE @JobScanOk BIT = 0;

IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;
CREATE TABLE #Evidence
(
    EvidenceType NVARCHAR(50)  NOT NULL,
    Category     NVARCHAR(30)  NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    ObjectName   NVARCHAR(512) NULL
);

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList (DatabaseName NVARCHAR(128) NOT NULL);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #DbList (DatabaseName) SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.state = 0
      AND d.database_id <> 2
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db NVARCHAR(128), @prefix NVARCHAR(300), @sql NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #DbList;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    BEGIN TRY
        /* Programmable objects whose definition references the performance DMVs */
        SET @sql = N'
        SELECT N''ProgrammableObject'', c.Category, @dbname,
               o.type_desc + N'': '' + s.name + N''.'' + o.name
        FROM ' + @prefix + N'sys.sql_modules AS m
        JOIN ' + @prefix + N'sys.objects  AS o ON o.object_id = m.object_id
        JOIN ' + @prefix + N'sys.schemas  AS s ON s.schema_id = o.schema_id
        CROSS APPLY (VALUES
            (N''Waits'',
                CASE WHEN m.definition LIKE N''%dm[_]os[_]wait[_]stats%''
                       OR m.definition LIKE N''%dm[_]exec[_]session[_]wait[_]stats%''
                       OR m.definition LIKE N''%query[_]store[_]wait[_]stats%''
                     THEN 1 ELSE 0 END),
            (N''MissingIndex'',
                CASE WHEN m.definition LIKE N''%dm[_]db[_]missing[_]index%''
                     THEN 1 ELSE 0 END),
            (N''IndexUsage'',
                CASE WHEN m.definition LIKE N''%dm[_]db[_]index[_]usage[_]stats%''
                       OR m.definition LIKE N''%dm[_]db[_]index[_]operational[_]stats%''
                     THEN 1 ELSE 0 END)
        ) AS c(Category, IsMatch)
        WHERE c.IsMatch = 1
          AND o.is_ms_shipped = 0;';

        INSERT INTO #Evidence (EvidenceType, Category, DatabaseName, ObjectName)
        EXEC sp_executesql @sql, N'@dbname NVARCHAR(128)', @dbname = @db;

        /* User tables that look like DMV capture / history tables */
        SET @sql = N'
        SELECT N''CollectionTable'', c.Category, @dbname, s.name + N''.'' + t.name
        FROM ' + @prefix + N'sys.tables  AS t
        JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
        CROSS APPLY (VALUES
            (N''Waits'',
                CASE WHEN t.name LIKE N''%wait%stat%'' THEN 1 ELSE 0 END),
            (N''MissingIndex'',
                CASE WHEN t.name LIKE N''%missing%index%'' THEN 1 ELSE 0 END),
            (N''IndexUsage'',
                CASE WHEN t.name LIKE N''%index%usage%''
                       OR t.name LIKE N''%unused%index%'' THEN 1 ELSE 0 END)
        ) AS c(Category, IsMatch)
        WHERE c.IsMatch = 1
          AND t.is_ms_shipped = 0;';

        INSERT INTO #Evidence (EvidenceType, Category, DatabaseName, ObjectName)
        EXEC sp_executesql @sql, N'@dbname NVARCHAR(128)', @dbname = @db;
    END TRY
    BEGIN CATCH
        SET @ScanErrors = @ScanErrors + 1;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* SQL Agent job steps that harvest the DMVs (not available on Azure SQL Database) */
IF @IsAzureDb = 0 AND DB_ID('msdb') IS NOT NULL
BEGIN
    BEGIN TRY
        INSERT INTO #Evidence (EvidenceType, Category, DatabaseName, ObjectName)
        SELECT N'AgentJobStep', c.Category, N'msdb',
               j.name + N' / step ' + CAST(js.step_id AS NVARCHAR(10)) + N': ' + js.step_name
        FROM msdb.dbo.sysjobs AS j
        JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = j.job_id
        CROSS APPLY (VALUES
            (N'Waits',
                CASE WHEN js.command LIKE N'%dm[_]os[_]wait[_]stats%'
                       OR js.command LIKE N'%dm[_]exec[_]session[_]wait[_]stats%'
                       OR js.command LIKE N'%query[_]store[_]wait[_]stats%'
                     THEN 1 ELSE 0 END),
            (N'MissingIndex',
                CASE WHEN js.command LIKE N'%dm[_]db[_]missing[_]index%'
                     THEN 1 ELSE 0 END),
            (N'IndexUsage',
                CASE WHEN js.command LIKE N'%dm[_]db[_]index[_]usage[_]stats%'
                       OR js.command LIKE N'%dm[_]db[_]index[_]operational[_]stats%'
                     THEN 1 ELSE 0 END)
        ) AS c(Category, IsMatch)
        WHERE c.IsMatch = 1
          AND j.enabled = 1;

        SET @JobScanOk = 1;
    END TRY
    BEGIN CATCH
        SET @ScanErrors = @ScanErrors + 1;
    END CATCH
END

/* Supporting context only - Query Store adoption */
DECLARE @QsDbCount INT = 0;
IF COL_LENGTH('sys.databases', 'is_query_store_on') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT @cnt = COUNT(*) FROM sys.databases WHERE state = 0 AND is_query_store_on = 1;';
        EXEC sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @QsDbCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @QsDbCount = 0;
    END CATCH
END

DECLARE @WaitEvidence INT = 0, @MissingEvidence INT = 0, @UsageEvidence INT = 0;
DECLARE @TotalEvidence INT = 0, @Categories INT = 0, @DbScanned INT = 0;

SELECT @DbScanned = COUNT(*) FROM #DbList;

SELECT @WaitEvidence    = SUM(CASE WHEN Category = N'Waits'        THEN 1 ELSE 0 END),
       @MissingEvidence = SUM(CASE WHEN Category = N'MissingIndex' THEN 1 ELSE 0 END),
       @UsageEvidence   = SUM(CASE WHEN Category = N'IndexUsage'   THEN 1 ELSE 0 END),
       @TotalEvidence   = COUNT(*)
FROM #Evidence;

SET @WaitEvidence    = ISNULL(@WaitEvidence, 0);
SET @MissingEvidence = ISNULL(@MissingEvidence, 0);
SET @UsageEvidence   = ISNULL(@UsageEvidence, 0);
SET @TotalEvidence   = ISNULL(@TotalEvidence, 0);

SET @Categories = CASE WHEN @WaitEvidence    > 0 THEN 1 ELSE 0 END
                + CASE WHEN @MissingEvidence > 0 THEN 1 ELSE 0 END
                + CASE WHEN @UsageEvidence   > 0 THEN 1 ELSE 0 END;

DECLARE @Samples NVARCHAR(MAX) = N'';

SELECT @Samples = ISNULL(STUFF((
        SELECT TOP (5) N'; ' + ISNULL(e.DatabaseName, N'(unknown)') + N'.'
                     + ISNULL(e.ObjectName, N'(unknown)') + N' [' + e.Category + N']'
        FROM #Evidence AS e
        ORDER BY e.EvidenceType, e.DatabaseName, e.ObjectName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'');

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);

SET @Score = CASE WHEN @Categories = 3 THEN 3
                  WHEN @Categories = 2 THEN 2
                  WHEN @Categories = 1 THEN 1
                  ELSE 0 END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding NVARCHAR(MAX) =
    N'Scanned ' + CAST(@DbScanned AS NVARCHAR(10)) + N' accessible database(s)'
    + CASE WHEN @JobScanOk = 1 THEN N' plus msdb Agent job steps' ELSE N'' END
    + N'. DMV performance-analysis artifacts found: ' + CAST(@TotalEvidence AS NVARCHAR(10))
    + N' (wait stats: ' + CAST(@WaitEvidence AS NVARCHAR(10))
    + N', missing index: ' + CAST(@MissingEvidence AS NVARCHAR(10))
    + N', index usage/unused: ' + CAST(@UsageEvidence AS NVARCHAR(10))
    + N'). Categories covered: ' + CAST(@Categories AS NVARCHAR(10)) + N' of 3.'
    + CASE WHEN @Samples <> N'' THEN N' Examples: ' + @Samples + N'.' ELSE N'' END
    + N' Query Store enabled on ' + CAST(@QsDbCount AS NVARCHAR(10)) + N' database(s) (supporting context only).'
    + CASE WHEN @Categories = 3
                THEN N' All three DMV categories are consumed by persisted objects or jobs, indicating ongoing DMV-based performance analysis.'
           WHEN @Categories = 2
                THEN N' Two of the three DMV categories are covered; the remaining category has no persisted consumer and should be added.'
           WHEN @Categories = 1
                THEN N' Only one DMV category is covered; ongoing performance analysis is incomplete.'
           ELSE N' No stored procedure, view, function, collection table or enabled Agent job references the wait-stats or index DMVs.' END
    + CASE WHEN @ScanErrors > 0
           THEN N' NOTE: ' + CAST(@ScanErrors AS NVARCHAR(10)) + N' scope(s) could not be scanned (permission or state); evidence may be understated.'
           ELSE N'' END
    + CASE WHEN @IsAzureDb = 1
           THEN N' NOTE: Azure SQL Database - only the current database was scanned and SQL Agent jobs do not exist.'
           ELSE N'' END;

IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;
IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;

SELECT @Result AS Result,
       @Score  AS Score,
       CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)) AS DatabaseQueried,
       @Finding AS Finding;