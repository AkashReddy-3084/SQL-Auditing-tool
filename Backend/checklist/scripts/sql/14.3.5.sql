/* Checklist 14.3.5 - Lock escalation understood and mitigated where problematic
   Read-only. No data, schema or configuration is modified. */
SET NOCOUNT ON;

DECLARE @EngineEdition   int  = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @SingleDbPlatform bit = CASE WHEN @EngineEdition IN (5, 6, 11) THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs
(
    DatabaseName sysname NOT NULL,
    DbId         int     NOT NULL
);

IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;
CREATE TABLE #Skipped
(
    DatabaseName sysname NOT NULL
);

IF OBJECT_ID('tempdb..#LockEsc') IS NOT NULL DROP TABLE #LockEsc;
CREATE TABLE #LockEsc
(
    DatabaseName       sysname      NOT NULL,
    SchemaName         sysname      NOT NULL,
    TableName          sysname      NOT NULL,
    LockEscalationDesc nvarchar(60) NULL,
    LockPromotionCount bigint       NOT NULL,
    RowCounts          bigint       NOT NULL
);

/* Target databases: the current database on single-database Azure platforms,
   otherwise every accessible read-write user database. */
IF @SingleDbPlatform = 1
BEGIN
    INSERT INTO #Dbs (DatabaseName, DbId)
    SELECT DB_NAME(), DB_ID();
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName, DbId)
    SELECT d.name, d.database_id
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = N'READ_WRITE';
END

DECLARE @DbName sysname,
        @DbId   int,
        @Prefix nvarchar(300),
        @Sql    nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, DbId FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName, @DbId;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        /* Three-part names only on platforms that allow cross-database references. */
        SET @Prefix = CASE WHEN @SingleDbPlatform = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

        SET @Sql = N'
        SELECT
            @p_db,
            s.name,
            t.name,
            t.lock_escalation_desc,
            ISNULL(ops.LockPromotionCount, 0),
            ISNULL(ps.RowCounts, 0)
        FROM ' + @Prefix + N'sys.tables AS t
        INNER JOIN ' + @Prefix + N'sys.schemas AS s
            ON s.schema_id = t.schema_id
        LEFT JOIN
        (
            SELECT ios.object_id, SUM(ios.index_lock_promotion_count) AS LockPromotionCount
            FROM sys.dm_db_index_operational_stats(@p_dbid, NULL, NULL, NULL) AS ios
            GROUP BY ios.object_id
        ) AS ops
            ON ops.object_id = t.object_id
        LEFT JOIN
        (
            SELECT dps.object_id, SUM(dps.row_count) AS RowCounts
            FROM ' + @Prefix + N'sys.dm_db_partition_stats AS dps
            WHERE dps.index_id IN (0, 1)
            GROUP BY dps.object_id
        ) AS ps
            ON ps.object_id = t.object_id
        WHERE t.is_ms_shipped = 0;';

        INSERT INTO #LockEsc
            (DatabaseName, SchemaName, TableName, LockEscalationDesc, LockPromotionCount, RowCounts)
        EXEC sp_executesql
             @Sql,
             N'@p_db sysname, @p_dbid int',
             @p_db   = @DbName,
             @p_dbid = @DbId;
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName) VALUES (@DbName);
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName, @DbId;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount          int    = (SELECT COUNT(*) FROM #Dbs);
DECLARE @SkippedCount     int    = (SELECT COUNT(*) FROM #Skipped);
DECLARE @TableCount       int    = (SELECT COUNT(*) FROM #LockEsc);
DECLARE @MitigatedCount   int    = (SELECT COUNT(*) FROM #LockEsc WHERE LockEscalationDesc IN (N'AUTO', N'DISABLE'));
DECLARE @EscalatingCount  int    = (SELECT COUNT(*) FROM #LockEsc WHERE LockPromotionCount > 1000);
DECLARE @HotUnmitigated   int    = (SELECT COUNT(*) FROM #LockEsc WHERE LockPromotionCount > 1000 AND LockEscalationDesc = N'TABLE');
DECLARE @TotalPromotions  bigint = (SELECT ISNULL(SUM(LockPromotionCount), 0) FROM #LockEsc);

DECLARE @UptimeDays int = NULL;
BEGIN TRY
    SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
    FROM sys.dm_os_sys_info AS si;
END TRY
BEGIN CATCH
    SET @UptimeDays = NULL;
END CATCH

DECLARE @TopOffenders nvarchar(max) =
(
    SELECT STUFF(
    (
        SELECT N'; ' + x.DatabaseName + N'.' + x.SchemaName + N'.' + x.TableName
               + N' [escalations=' + CONVERT(nvarchar(20), x.LockPromotionCount)
               + N', setting=' + ISNULL(x.LockEscalationDesc, N'UNKNOWN')
               + N', rows=' + CONVERT(nvarchar(20), x.RowCounts) + N']'
        FROM
        (
            SELECT TOP (5) l.DatabaseName, l.SchemaName, l.TableName,
                           l.LockEscalationDesc, l.LockPromotionCount, l.RowCounts
            FROM #LockEsc AS l
            WHERE l.LockPromotionCount > 0
            ORDER BY l.LockPromotionCount DESC
        ) AS x
        ORDER BY x.LockPromotionCount DESC
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'')
);

DECLARE @SkippedList nvarchar(max) =
(
    SELECT STUFF(
    (
        SELECT N', ' + s.DatabaseName
        FROM #Skipped AS s
        ORDER BY s.DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'')
);

DECLARE @DbList nvarchar(max) =
(
    SELECT STUFF(
    (
        SELECT N', ' + d.DatabaseName
        FROM #Dbs AS d
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'')
);

IF @DbList IS NULL SET @DbList = N'None';
IF LEN(@DbList) > 900 SET @DbList = LEFT(@DbList, 900) + N'... (' + CONVERT(nvarchar(10), @DbCount) + N' databases)';

DECLARE @Result  nvarchar(50);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible read-write user database was found, so lock escalation configuration and escalation activity could not be assessed. Re-run with an account holding VIEW SERVER STATE and VIEW DATABASE STATE on the application databases.';
END
ELSE
BEGIN
    SET @Score =
        CASE
            WHEN @HotUnmitigated = 0  THEN 3
            WHEN @HotUnmitigated <= 5 THEN 2
            ELSE 1
        END;

    SET @Finding =
        N'Inspected ' + CONVERT(nvarchar(20), @TableCount) + N' user table(s) across '
      + CONVERT(nvarchar(10), @DbCount) + N' database(s). '
      + CONVERT(nvarchar(20), @TotalPromotions) + N' cumulative lock escalation(s) recorded; '
      + CONVERT(nvarchar(20), @EscalatingCount) + N' table(s) exceed the 1000-escalation threshold, of which '
      + CONVERT(nvarchar(20), @HotUnmitigated) + N' still use the default LOCK_ESCALATION = TABLE (unmitigated). '
      + CONVERT(nvarchar(20), @MitigatedCount) + N' table(s) have LOCK_ESCALATION explicitly set to AUTO or DISABLE.'
      + CASE WHEN @TopOffenders IS NULL THEN N' No table has recorded any lock escalation.'
             ELSE N' Highest escalation counts: ' + @TopOffenders + N'.' END
      + CASE WHEN @UptimeDays IS NULL THEN N''
             ELSE N' Counters are cumulative since the database came online; SQL Server uptime is '
                  + CONVERT(nvarchar(10), @UptimeDays) + N' day(s).' END
      + CASE WHEN @SkippedCount > 0
             THEN N' ' + CONVERT(nvarchar(10), @SkippedCount) + N' database(s) could not be read and were excluded: ' + ISNULL(@SkippedList, N'') + N'.'
             ELSE N'' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#LockEsc') IS NOT NULL DROP TABLE #LockEsc;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;