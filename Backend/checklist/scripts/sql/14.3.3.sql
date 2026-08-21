SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(500);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE @DbIsolation TABLE
(
    DatabaseName SYSNAME NOT NULL,
    RcsiOn       BIT     NOT NULL,
    SnapshotOn   BIT     NOT NULL
);

INSERT INTO @DbIsolation (DatabaseName, RcsiOn, SnapshotOn)
SELECT d.name,
       CASE WHEN d.is_read_committed_snapshot_on = 1 THEN 1 ELSE 0 END,
       CASE WHEN d.snapshot_isolation_state = 1 THEN 1 ELSE 0 END
FROM sys.databases AS d
WHERE d.name NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution')
  AND d.state = 0
  AND d.is_read_only = 0
  AND d.source_database_id IS NULL;

DECLARE @LockWaitMs  BIGINT = NULL;
DECLARE @TotalWaitMs BIGINT = NULL;
DECLARE @WaitSql     NVARCHAR(1000);

SET @WaitSql =
    CASE WHEN @EngineEdition = 5
         THEN N'SELECT @lck = SUM(CASE WHEN wait_type LIKE ''LCK_M_%'' THEN wait_time_ms ELSE 0 END), @tot = SUM(wait_time_ms) FROM sys.dm_db_wait_stats;'
         ELSE N'SELECT @lck = SUM(CASE WHEN wait_type LIKE ''LCK_M_%'' THEN wait_time_ms ELSE 0 END), @tot = SUM(wait_time_ms) FROM sys.dm_os_wait_stats;'
    END;

BEGIN TRY
    EXEC sp_executesql @WaitSql,
         N'@lck BIGINT OUTPUT, @tot BIGINT OUTPUT',
         @lck = @LockWaitMs OUTPUT,
         @tot = @TotalWaitMs OUTPUT;
END TRY
BEGIN CATCH
    SET @LockWaitMs  = NULL;
    SET @TotalWaitMs = NULL;
END CATCH;

DECLARE @LockWaitPct DECIMAL(9, 2) =
    CASE WHEN ISNULL(@TotalWaitMs, 0) > 0
         THEN CAST(100.0 * @LockWaitMs / @TotalWaitMs AS DECIMAL(9, 2))
    END;

DECLARE @TotalDbs      INT = (SELECT COUNT(*) FROM @DbIsolation);
DECLARE @ConfiguredDbs INT = (SELECT COUNT(*) FROM @DbIsolation WHERE RcsiOn = 1 OR SnapshotOn = 1);
DECLARE @RcsiDbs       INT = (SELECT COUNT(*) FROM @DbIsolation WHERE RcsiOn = 1);
DECLARE @SnapDbs       INT = (SELECT COUNT(*) FROM @DbIsolation WHERE SnapshotOn = 1);

DECLARE @ConfiguredList   NVARCHAR(MAX);
DECLARE @UnconfiguredList NVARCHAR(MAX);
DECLARE @AllDbList        NVARCHAR(MAX);

SELECT @ConfiguredList = STUFF((
    SELECT N', ' + i.DatabaseName + N' ['
         + CASE WHEN i.RcsiOn = 1 THEN N'RCSI' ELSE N'' END
         + CASE WHEN i.RcsiOn = 1 AND i.SnapshotOn = 1 THEN N'+' ELSE N'' END
         + CASE WHEN i.SnapshotOn = 1 THEN N'SNAPSHOT' ELSE N'' END
         + N']'
    FROM @DbIsolation AS i
    WHERE i.RcsiOn = 1 OR i.SnapshotOn = 1
    ORDER BY i.DatabaseName
    FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @UnconfiguredList = STUFF((
    SELECT N', ' + i.DatabaseName
    FROM @DbIsolation AS i
    WHERE i.RcsiOn = 0 AND i.SnapshotOn = 0
    ORDER BY i.DatabaseName
    FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @AllDbList = STUFF((
    SELECT N', ' + i.DatabaseName
    FROM @DbIsolation AS i
    ORDER BY i.DatabaseName
    FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = LEFT(ISNULL(NULLIF(@AllDbList, N''), DB_NAME()), 500);

DECLARE @WaitEvidence NVARCHAR(300) =
    CASE WHEN @LockWaitPct IS NULL
         THEN N' Instance lock-wait evidence was unavailable (wait statistics DMV not readable with the current permissions).'
         ELSE N' Instance-wide LCK_M_* lock waits account for ' + CONVERT(NVARCHAR(20), @LockWaitPct)
              + N'% of total accumulated wait time since the last wait-statistics reset.'
    END;

IF @TotalDbs = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No ONLINE, writable user databases were found on this instance (only system databases, read-only databases or database snapshots are present), so database-level isolation configuration is not applicable.'
                 + @WaitEvidence;
END
ELSE IF @ConfiguredDbs = @TotalDbs
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CONVERT(NVARCHAR(20), @TotalDbs) + N' user database(s) have a row-versioning isolation option enabled: '
                 + CONVERT(NVARCHAR(20), @RcsiDbs) + N' with READ_COMMITTED_SNAPSHOT ON and '
                 + CONVERT(NVARCHAR(20), @SnapDbs) + N' with ALLOW_SNAPSHOT_ISOLATION ON. Configured databases: '
                 + LEFT(ISNULL(@ConfiguredList, N'(none)'), 1200) + N'.'
                 + @WaitEvidence;
END
ELSE IF @ConfiguredDbs > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Only ' + CONVERT(NVARCHAR(20), @ConfiguredDbs) + N' of ' + CONVERT(NVARCHAR(20), @TotalDbs)
                 + N' user database(s) have a row-versioning isolation option enabled ('
                 + CONVERT(NVARCHAR(20), @RcsiDbs) + N' RCSI, ' + CONVERT(NVARCHAR(20), @SnapDbs) + N' snapshot isolation). Configured: '
                 + LEFT(ISNULL(@ConfiguredList, N'(none)'), 800)
                 + N'. Still on default pessimistic READ COMMITTED locking: '
                 + LEFT(ISNULL(@UnconfiguredList, N'(none)'), 800) + N'.'
                 + @WaitEvidence;
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'None of the ' + CONVERT(NVARCHAR(20), @TotalDbs)
                 + N' user database(s) have READ_COMMITTED_SNAPSHOT or ALLOW_SNAPSHOT_ISOLATION enabled; every database runs on the default pessimistic READ COMMITTED locking model. Databases without any row-versioning isolation: '
                 + LEFT(ISNULL(@UnconfiguredList, N'(none)'), 1200) + N'.'
                 + @WaitEvidence;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;