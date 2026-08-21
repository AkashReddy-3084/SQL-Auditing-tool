/* Checklist 3.3.5 - Deadlock-prone patterns avoided; retry logic where needed. Strictly read-only. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#DbInfo') IS NOT NULL DROP TABLE #DbInfo;

CREATE TABLE #Modules
(
    DatabaseName      SYSNAME      NOT NULL,
    SchemaName        SYSNAME      NOT NULL,
    ObjectName        SYSNAME      NOT NULL,
    ObjectType        NVARCHAR(60) NOT NULL,
    HasTxn            BIT          NOT NULL,
    MultiWrite        BIT          NOT NULL,
    HasRetry          BIT          NOT NULL,
    HasLockMitigation BIT          NOT NULL
);

CREATE TABLE #DbInfo
(
    DatabaseName SYSNAME NOT NULL,
    IsRcsiOn     BIT     NOT NULL,
    IsSnapshotOn BIT     NOT NULL
);

DECLARE @EngineEdition  INT           = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Template       NVARCHAR(MAX);
DECLARE @Sql            NVARCHAR(MAX);
DECLARE @Db             SYSNAME;
DECLARE @Deadlocks      BIGINT        = 0;
DECLARE @DbCount        INT           = 0;
DECLARE @RcsiDbs        INT           = 0;
DECLARE @TotalModules   INT           = 0;
DECLARE @TxnMultiWrite  INT           = 0;
DECLARE @Risky          INT           = 0;
DECLARE @RetryModules   INT           = 0;
DECLARE @Mitigated      INT           = 0;
DECLARE @RiskyPct       DECIMAL(9, 2) = 0;
DECLARE @Sample         NVARCHAR(1000);
DECLARE @DbList         NVARCHAR(4000);
DECLARE @Score          INT           = 0;
DECLARE @Result         NVARCHAR(50);
DECLARE @Finding        NVARCHAR(4000);

/* Cumulative deadlock count since the last engine restart. */
BEGIN TRY
    SELECT @Deadlocks = MAX(CONVERT(BIGINT, pc.cntr_value))
    FROM sys.dm_os_performance_counters AS pc
    WHERE pc.counter_name LIKE N'Number of Deadlocks/sec%'
      AND LTRIM(RTRIM(pc.instance_name)) = N'_Total';
END TRY
BEGIN CATCH
    SET @Deadlocks = 0;
END CATCH

SET @Deadlocks = ISNULL(@Deadlocks, 0);

IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbInfo (DatabaseName, IsRcsiOn, IsSnapshotOn)
    SELECT DB_NAME(),
           d.is_read_committed_snapshot_on,
           CASE WHEN d.snapshot_isolation_state = 1 THEN 1 ELSE 0 END
    FROM sys.databases AS d
    WHERE d.database_id = DB_ID();
END
ELSE
BEGIN
    INSERT INTO #DbInfo (DatabaseName, IsRcsiOn, IsSnapshotOn)
    SELECT d.name,
           d.is_read_committed_snapshot_on,
           CASE WHEN d.snapshot_isolation_state = 1 THEN 1 ELSE 0 END
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

SET @Template = N'
INSERT INTO #Modules (DatabaseName, SchemaName, ObjectName, ObjectType, HasTxn, MultiWrite, HasRetry, HasLockMitigation)
SELECT
    @dbn,
    s.name,
    o.name,
    o.type_desc,
    CASE WHEN d.def LIKE N''%BEGIN TRAN%'' THEN 1 ELSE 0 END,
    CASE WHEN (CASE WHEN d.def LIKE N''%INSERT %'' THEN 1 ELSE 0 END
             + CASE WHEN d.def LIKE N''%UPDATE %'' THEN 1 ELSE 0 END
             + CASE WHEN d.def LIKE N''%DELETE %'' THEN 1 ELSE 0 END
             + CASE WHEN d.def LIKE N''%MERGE %''  THEN 1 ELSE 0 END) >= 2
         THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%BEGIN TRY%''
          AND d.def LIKE N''%BEGIN CATCH%''
          AND (d.def LIKE N''%1205%'' OR d.def LIKE N''%ERROR_NUMBER%'')
          AND (d.def LIKE N''%WHILE%'' OR d.def LIKE N''%RETRY%'')
         THEN 1 ELSE 0 END,
    CASE WHEN d.def LIKE N''%DEADLOCK_PRIORITY%''
           OR d.def LIKE N''%UPDLOCK%''
           OR d.def LIKE N''%READPAST%''
           OR d.def LIKE N''%SNAPSHOT%''
         THEN 1 ELSE 0 END
FROM {DB}sys.sql_modules AS m
INNER JOIN {DB}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {DB}sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY (VALUES (UPPER(REPLACE(REPLACE(m.definition, CHAR(13), N'' ''), CHAR(10), N'' '')))) AS d(def)
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''TR'', ''FN'', ''TF'', ''IF'')
  AND m.definition IS NOT NULL;';

IF @EngineEdition = 5
BEGIN
    SET @Sql = REPLACE(@Template, N'{DB}', N'');
    SET @Db = DB_NAME();

    BEGIN TRY
        EXEC sys.sp_executesql @Sql, N'@dbn SYSNAME', @dbn = @Db;
    END TRY
    BEGIN CATCH
        PRINT N'Skipped database ' + @Db + N': ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM #DbInfo ORDER BY DatabaseName;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(@Template, N'{DB}', QUOTENAME(@Db) + N'.');

        BEGIN TRY
            EXEC sys.sp_executesql @Sql, N'@dbn SYSNAME', @dbn = @Db;
        END TRY
        BEGIN CATCH
            PRINT N'Skipped database ' + @Db + N': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cur INTO @Db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

SELECT @DbCount = COUNT(*),
       @RcsiDbs = SUM(CASE WHEN IsRcsiOn = 1 OR IsSnapshotOn = 1 THEN 1 ELSE 0 END)
FROM #DbInfo;

SELECT @TotalModules  = COUNT(*),
       @TxnMultiWrite = SUM(CASE WHEN HasTxn = 1 AND MultiWrite = 1 THEN 1 ELSE 0 END),
       @Risky         = SUM(CASE WHEN HasTxn = 1 AND MultiWrite = 1 AND HasRetry = 0 THEN 1 ELSE 0 END),
       @RetryModules  = SUM(CASE WHEN HasRetry = 1 THEN 1 ELSE 0 END),
       @Mitigated     = SUM(CASE WHEN HasLockMitigation = 1 THEN 1 ELSE 0 END)
FROM #Modules;

SET @DbCount       = ISNULL(@DbCount, 0);
SET @TotalModules  = ISNULL(@TotalModules, 0);
SET @TxnMultiWrite = ISNULL(@TxnMultiWrite, 0);
SET @Risky         = ISNULL(@Risky, 0);
SET @RetryModules  = ISNULL(@RetryModules, 0);
SET @Mitigated     = ISNULL(@Mitigated, 0);
SET @RcsiDbs       = ISNULL(@RcsiDbs, 0);

SET @DbList = STUFF((
    SELECT TOP (50) N', ' + i.DatabaseName
    FROM #DbInfo AS i
    ORDER BY i.DatabaseName
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(4000)'), 1, 2, N'');

SET @Sample = STUFF((
    SELECT TOP (5) N', ' + x.DatabaseName + N'.' + x.SchemaName + N'.' + x.ObjectName
    FROM #Modules AS x
    WHERE x.HasTxn = 1 AND x.MultiWrite = 1 AND x.HasRetry = 0
    ORDER BY x.DatabaseName, x.SchemaName, x.ObjectName
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @DbList = N'None';
    SET @Finding = N'No accessible user database was found on this instance, so T-SQL modules could not be inspected for deadlock-prone patterns or retry logic. Grant the audit login VIEW DEFINITION / VIEW ANY DEFINITION and re-run.';
END
ELSE IF @TotalModules = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user-defined T-SQL modules exist in the ' + CONVERT(NVARCHAR(20), @DbCount)
                 + N' database(s) inspected (' + @DbList + N'), so no deadlock-prone module patterns are present. Recorded deadlocks since last restart: '
                 + CONVERT(NVARCHAR(20), @Deadlocks) + N'.';
END
ELSE
BEGIN
    SET @RiskyPct = CASE WHEN @TxnMultiWrite = 0 THEN 0
                         ELSE CONVERT(DECIMAL(9, 2), @Risky) * 100.0 / @TxnMultiWrite END;

    SET @Score = CASE
                     WHEN @Risky = 0 AND @Deadlocks = 0 THEN 3
                     WHEN @Risky = 0 AND @Deadlocks > 0 THEN 2
                     WHEN @RiskyPct <= 25.00 THEN 2
                     WHEN @RiskyPct <= 60.00 THEN 1
                     ELSE 0
                 END;

    SET @Finding = N'Inspected ' + CONVERT(NVARCHAR(20), @TotalModules) + N' user T-SQL module(s) across '
                 + CONVERT(NVARCHAR(20), @DbCount) + N' database(s). '
                 + CONVERT(NVARCHAR(20), @TxnMultiWrite) + N' module(s) perform multi-object writes inside an explicit transaction; '
                 + CONVERT(NVARCHAR(20), @Risky) + N' of those ('
                 + CONVERT(NVARCHAR(20), @RiskyPct) + N'%) contain no deadlock retry logic (no TRY/CATCH loop handling error 1205). '
                 + CONVERT(NVARCHAR(20), @RetryModules) + N' module(s) implement retry logic and '
                 + CONVERT(NVARCHAR(20), @Mitigated) + N' use lock/isolation mitigations (UPDLOCK, READPAST, SNAPSHOT or DEADLOCK_PRIORITY). '
                 + CONVERT(NVARCHAR(20), @RcsiDbs) + N' of ' + CONVERT(NVARCHAR(20), @DbCount)
                 + N' database(s) have RCSI or snapshot isolation enabled. Deadlocks recorded since last restart: '
                 + CONVERT(NVARCHAR(20), @Deadlocks) + N'.'
                 + CASE WHEN @Sample IS NULL THEN N'' ELSE N' Examples without retry logic: ' + @Sample + N'.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                  AS Result,
    @Score                   AS Score,
    ISNULL(@DbList, N'None') AS DatabaseQueried,
    @Finding                 AS Finding;

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#DbInfo') IS NOT NULL DROP TABLE #DbInfo;