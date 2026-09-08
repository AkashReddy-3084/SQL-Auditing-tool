SET NOCOUNT ON;

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried NVARCHAR(4000);
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);

IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;
CREATE TABLE #TargetDatabases (DatabaseName SYSNAME NOT NULL);

IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;
CREATE TABLE #Evidence
(
    EvidenceType NVARCHAR(30) NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    Detail       NVARCHAR(400) NULL
);

/* Azure SQL Database exposes only the current database; on other editions enumerate accessible user databases. */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #TargetDatabases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #TargetDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #TargetDatabases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* Query Store retains per-query wait statistics available for routine review. */
    BEGIN TRY
        SET @Sql = N'SELECT ''QueryStore'', @db, ''Query Store actual_state_desc = '' + ISNULL(qso.actual_state_desc, ''UNKNOWN'')
                     FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options AS qso
                     WHERE qso.actual_state = 2;';

        INSERT INTO #Evidence (EvidenceType, DatabaseName, Detail)
        EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
    END TRY
    BEGIN CATCH
        /* Query Store catalog view unavailable or inaccessible in this database. */
    END CATCH;

    /* User objects that persist wait-statistics snapshots indicate routine collection for tuning. */
    BEGIN TRY
        SET @Sql = N'SELECT ''WaitStatsObject'', @db, ''Persisted wait-statistics object: '' + s.name + ''.'' + o.name + '' ('' + o.type_desc + '')''
                     FROM ' + QUOTENAME(@DbName) + N'.sys.objects AS o
                     INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
                         ON s.schema_id = o.schema_id
                     WHERE o.is_ms_shipped = 0
                       AND o.type IN (''U'', ''V'')
                       AND o.name LIKE ''%wait%''
                       AND (o.name LIKE ''%stat%'' OR o.name LIKE ''%snap%'' OR o.name LIKE ''%hist%'' OR o.name LIKE ''%capture%'' OR o.name LIKE ''%collect%'');';

        INSERT INTO #Evidence (EvidenceType, DatabaseName, Detail)
        EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
    END TRY
    BEGIN CATCH
        /* Database not accessible for object enumeration. */
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* SQL Agent jobs that read wait-statistics DMVs evidence routine, repeatable wait-stats review. */
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        INSERT INTO #Evidence (EvidenceType, DatabaseName, Detail)
        SELECT DISTINCT
               'CollectionJob',
               'msdb',
               'Enabled SQL Agent job referencing wait statistics: ' + j.name
               + CASE WHEN EXISTS (SELECT 1
                                   FROM msdb.dbo.sysjobschedules AS js
                                   INNER JOIN msdb.dbo.sysschedules AS sch ON sch.schedule_id = js.schedule_id
                                   WHERE js.job_id = j.job_id AND sch.enabled = 1)
                      THEN ' (enabled schedule)'
                      ELSE ' (no enabled schedule)'
                 END
        FROM msdb.dbo.sysjobs AS j
        INNER JOIN msdb.dbo.sysjobsteps AS st
            ON st.job_id = j.job_id
        WHERE j.enabled = 1
          AND (st.command LIKE '%dm_os_wait_stats%'
            OR st.command LIKE '%dm_db_wait_stats%'
            OR st.command LIKE '%dm_exec_session_wait_stats%'
            OR st.command LIKE '%query_store_wait_stats%'
            OR st.command LIKE '%dm_os_waiting_tasks%');
    END TRY
    BEGIN CATCH
        /* msdb not accessible with the current permissions. */
    END CATCH;
END

DECLARE @JobCount INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'CollectionJob');
DECLARE @ObjectCount INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'WaitStatsObject');
DECLARE @QueryStoreCount INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'QueryStore');
DECLARE @DbCount INT = (SELECT COUNT(*) FROM #TargetDatabases);

SELECT @DatabaseQueried = STUFF((SELECT ',' + t.DatabaseName
                                 FROM #TargetDatabases AS t
                                 ORDER BY t.DatabaseName
                                 FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '');

IF @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
    SET @DatabaseQueried = N'SERVER';

DECLARE @Examples NVARCHAR(2000);
SELECT @Examples = STUFF((SELECT '; ' + e.Detail
                          FROM (SELECT TOP (5) e2.Detail, e2.EvidenceType
                                FROM #Evidence AS e2
                                ORDER BY CASE e2.EvidenceType WHEN 'CollectionJob' THEN 1 WHEN 'WaitStatsObject' THEN 2 ELSE 3 END, e2.Detail) AS e
                          ORDER BY CASE e.EvidenceType WHEN 'CollectionJob' THEN 1 WHEN 'WaitStatsObject' THEN 2 ELSE 3 END, e.Detail
                          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

IF @JobCount > 0 OR @ObjectCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Routine wait-statistics collection is in place: '
                   + CAST(@JobCount AS NVARCHAR(10)) + N' enabled SQL Agent job step(s) referencing wait-statistics DMVs and '
                   + CAST(@ObjectCount AS NVARCHAR(10)) + N' persisted wait-statistics object(s) across '
                   + CAST(@DbCount AS NVARCHAR(10)) + N' database(s); Query Store is READ_WRITE in '
                   + CAST(@QueryStoreCount AS NVARCHAR(10)) + N' database(s). Evidence: ' + ISNULL(@Examples, N'n/a') + N'.';
END
ELSE IF @QueryStoreCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No wait-statistics collection job and no persisted wait-statistics object were found, but Query Store is READ_WRITE in '
                   + CAST(@QueryStoreCount AS NVARCHAR(10)) + N' of ' + CAST(@DbCount AS NVARCHAR(10))
                   + N' database(s), so query wait statistics are retained but there is no evidence of routine collection or review. Evidence: '
                   + ISNULL(@Examples, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'No evidence of routine wait-statistics review was found: no enabled SQL Agent job references wait-statistics DMVs, no user object persists wait-statistics snapshots, and Query Store is not READ_WRITE in any of the '
                   + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) examined.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;