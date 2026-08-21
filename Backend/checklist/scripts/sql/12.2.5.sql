SET NOCOUNT ON;

/* Checklist 12.2.5 - Unused databases/objects/indexes cleaned up. Strictly read-only. */

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @UptimeDays   int = 0;

SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
FROM sys.dm_os_sys_info AS si;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
CREATE TABLE #Databases (DatabaseName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings
(
    DatabaseName     sysname        NOT NULL,
    UnusedIndexes    int            NULL,
    NeverUsedIndexes int            NULL,
    EmptyTables      int            NULL,
    ErrorMessage     nvarchar(2000) NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Databases (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL          /* skip database snapshots */
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName      sysname,
        @Prefix      nvarchar(300),
        @DbIdExpr    nvarchar(100),
        @Sql         nvarchar(max),
        @Unused      int,
        @NeverUsed   int,
        @EmptyTables int;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Unused      = NULL;
    SET @NeverUsed   = NULL;
    SET @EmptyTables = NULL;

    SET @Prefix   = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;
    SET @DbIdExpr = CASE WHEN @IsAzureSqlDb = 1 THEN N'DB_ID()' ELSE N'DB_ID(@p_DbName)' END;

    BEGIN TRY
        SET @Sql = N'
SELECT
    @p_Unused    = SUM(CASE WHEN x.HasStats = 1 AND x.UsageTotal = 0 THEN 1 ELSE 0 END),
    @p_NeverUsed = SUM(CASE WHEN x.HasStats = 0 THEN 1 ELSE 0 END)
FROM
(
    SELECT
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS UsageTotal,
        CASE WHEN us.index_id IS NULL THEN 0 ELSE 1 END AS HasStats
    FROM ' + @Prefix + N'sys.indexes AS i
    INNER JOIN ' + @Prefix + N'sys.objects AS o
        ON o.object_id = i.object_id
    LEFT JOIN sys.dm_db_index_usage_stats AS us
        ON us.database_id = ' + @DbIdExpr + N'
       AND us.object_id   = i.object_id
       AND us.index_id    = i.index_id
    WHERE o.is_ms_shipped        = 0
      AND o.type                 = ''U''
      AND i.type_desc            = ''NONCLUSTERED''
      AND i.is_primary_key       = 0
      AND i.is_unique            = 0
      AND i.is_unique_constraint = 0
      AND i.is_disabled          = 0
      AND i.is_hypothetical      = 0
) AS x;

SELECT @p_EmptyTables = COUNT(*)
FROM
(
    SELECT ps.object_id
    FROM ' + @Prefix + N'sys.dm_db_partition_stats AS ps
    INNER JOIN ' + @Prefix + N'sys.objects AS o
        ON o.object_id = ps.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type          = ''U''
      AND ps.index_id IN (0, 1)
    GROUP BY ps.object_id
    HAVING SUM(ps.row_count) = 0
) AS t;';

        EXEC sys.sp_executesql
             @Sql,
             N'@p_DbName sysname, @p_Unused int OUTPUT, @p_NeverUsed int OUTPUT, @p_EmptyTables int OUTPUT',
             @p_DbName      = @DbName,
             @p_Unused      = @Unused      OUTPUT,
             @p_NeverUsed   = @NeverUsed   OUTPUT,
             @p_EmptyTables = @EmptyTables OUTPUT;

        INSERT INTO #Findings (DatabaseName, UnusedIndexes, NeverUsedIndexes, EmptyTables, ErrorMessage)
        VALUES (@DbName, ISNULL(@Unused, 0), ISNULL(@NeverUsed, 0), ISNULL(@EmptyTables, 0), NULL);
    END TRY
    BEGIN CATCH
        INSERT INTO #Findings (DatabaseName, UnusedIndexes, NeverUsedIndexes, EmptyTables, ErrorMessage)
        VALUES (@DbName, NULL, NULL, NULL, LEFT(ERROR_MESSAGE(), 2000));
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbInScope      int = (SELECT COUNT(*) FROM #Databases),
        @DbEvaluated    int = 0,
        @DbFailed       int = 0,
        @TotalUnused    int = 0,
        @TotalNeverUsed int = 0,
        @TotalEmpty     int = 0,
        @DirtyDbCount   int = 0;

SELECT
    @DbEvaluated    = SUM(CASE WHEN f.ErrorMessage IS NULL THEN 1 ELSE 0 END),
    @DbFailed       = SUM(CASE WHEN f.ErrorMessage IS NOT NULL THEN 1 ELSE 0 END),
    @TotalUnused    = ISNULL(SUM(f.UnusedIndexes), 0),
    @TotalNeverUsed = ISNULL(SUM(f.NeverUsedIndexes), 0),
    @TotalEmpty     = ISNULL(SUM(f.EmptyTables), 0),
    @DirtyDbCount   = SUM(CASE WHEN f.ErrorMessage IS NULL
                                AND (f.UnusedIndexes + f.NeverUsedIndexes + f.EmptyTables) > 0
                               THEN 1 ELSE 0 END)
FROM #Findings AS f;

SET @DbEvaluated  = ISNULL(@DbEvaluated, 0);
SET @DbFailed     = ISNULL(@DbFailed, 0);
SET @DirtyDbCount = ISNULL(@DirtyDbCount, 0);

DECLARE @UnusedCandidates int = @TotalUnused + @TotalNeverUsed;

DECLARE @DatabaseQueried nvarchar(max),
        @Detail          nvarchar(max),
        @Result          nvarchar(20),
        @Score           int,
        @Finding         nvarchar(max);

SELECT @DatabaseQueried = STUFF(
    (SELECT N', ' + f.DatabaseName
     FROM #Findings AS f
     ORDER BY f.DatabaseName
     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @DatabaseQueried = ISNULL(LEFT(@DatabaseQueried, 3900), N'No accessible user databases');

SELECT @Detail = STUFF(
    (SELECT TOP (10) N'; ' + f.DatabaseName + N': '
            + CAST(f.UnusedIndexes + f.NeverUsedIndexes AS varchar(10)) + N' unused index(es), '
            + CAST(f.EmptyTables AS varchar(10)) + N' empty table(s)'
     FROM #Findings AS f
     WHERE f.ErrorMessage IS NULL
       AND (f.UnusedIndexes + f.NeverUsedIndexes + f.EmptyTables) > 0
     ORDER BY (f.UnusedIndexes + f.NeverUsedIndexes + f.EmptyTables) DESC, f.DatabaseName
     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @Detail = ISNULL(@Detail, N'none');

IF @DbEvaluated = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No user database could be interrogated for unused objects: '
                 + CAST(@DbInScope AS varchar(10)) + N' database(s) in scope, '
                 + CAST(@DbFailed AS varchar(10)) + N' returned an error. Unused-object cleanup could not be evidenced; manual review required.';
END
ELSE IF @UptimeDays < 7
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Index usage statistics span only ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s) since the last SQL Server start, which is too short to prove that an index or table is genuinely unused. Provisional counts across '
                 + CAST(@DbEvaluated AS varchar(10)) + N' database(s): '
                 + CAST(@TotalUnused AS varchar(10)) + N' nonclustered index(es) with zero reads, '
                 + CAST(@TotalNeverUsed AS varchar(10)) + N' with no usage entry at all, '
                 + CAST(@TotalEmpty AS varchar(10)) + N' zero-row user table(s). Re-run after at least 7 days of uptime; manual review required.';
END
ELSE IF @UnusedCandidates = 0 AND @TotalEmpty = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No cleanup candidates found across ' + CAST(@DbEvaluated AS varchar(10))
                 + N' user database(s) over ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s) of uptime: every non-unique nonclustered index has recorded reads and no user table is empty.';
END
ELSE IF @UnusedCandidates <= 5 AND @TotalEmpty <= 5
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Minor residue after ' + CAST(@UptimeDays AS varchar(10)) + N' day(s) of uptime across '
                 + CAST(@DbEvaluated AS varchar(10)) + N' database(s): '
                 + CAST(@TotalUnused AS varchar(10)) + N' nonclustered index(es) with zero reads, '
                 + CAST(@TotalNeverUsed AS varchar(10)) + N' index(es) with no usage entry at all and '
                 + CAST(@TotalEmpty AS varchar(10)) + N' zero-row user table(s) remain in '
                 + CAST(@DirtyDbCount AS varchar(10)) + N' database(s). Detail: ' + @Detail + N'.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Unused objects are not being cleaned up: after ' + CAST(@UptimeDays AS varchar(10))
                 + N' day(s) of uptime, ' + CAST(@TotalUnused AS varchar(10))
                 + N' nonclustered index(es) have zero reads, ' + CAST(@TotalNeverUsed AS varchar(10))
                 + N' have no usage entry at all and ' + CAST(@TotalEmpty AS varchar(10))
                 + N' user table(s) hold 0 rows, spread over ' + CAST(@DirtyDbCount AS varchar(10))
                 + N' of ' + CAST(@DbEvaluated AS varchar(10)) + N' database(s). Top offenders: ' + @Detail + N'.';
END

IF @DbFailed > 0 AND @DbEvaluated > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@DbFailed AS varchar(10))
                 + N' database(s) could not be interrogated and are excluded from these counts.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;