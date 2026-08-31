SET NOCOUNT ON;

DECLARE @DatabaseQueried  nvarchar(max) = N'None';
DECLARE @Result           nvarchar(20)  = N'Fail';
DECLARE @Score            int           = 0;
DECLARE @Finding          nvarchar(max) = N'No database found to be queried';

BEGIN TRY
    DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

    IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;
    IF OBJECT_ID('tempdb..#IsolationModules') IS NOT NULL DROP TABLE #IsolationModules;

    CREATE TABLE #TargetDatabases
    (
        DatabaseName      sysname  NOT NULL PRIMARY KEY,
        RcsiOn            bit      NOT NULL,
        SnapshotIsoState  tinyint  NOT NULL,
        Scanned           bit      NOT NULL DEFAULT (0)
    );

    CREATE TABLE #IsolationModules
    (
        DatabaseName      sysname       NOT NULL,
        SchemaName        sysname       NOT NULL,
        ObjectName        sysname       NOT NULL,
        ObjectType        nvarchar(60)  NOT NULL,
        UsesSerializable  bit           NOT NULL,
        UsesRepeatable    bit           NOT NULL,
        UsesReadUncommit  bit           NOT NULL,
        UsesSnapshot      bit           NOT NULL,
        UsesNoLockHint    bit           NOT NULL
    );

    IF @IsAzureSqlDb = 1
    BEGIN
        -- Azure SQL Database allows no cross-database access; only the current database can be inspected.
        INSERT INTO #TargetDatabases (DatabaseName, RcsiOn, SnapshotIsoState)
        SELECT d.name, CONVERT(bit, d.is_read_committed_snapshot_on), CONVERT(tinyint, d.snapshot_isolation_state)
        FROM sys.databases AS d
        WHERE d.database_id = DB_ID()
          AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb');
    END
    ELSE
    BEGIN
        INSERT INTO #TargetDatabases (DatabaseName, RcsiOn, SnapshotIsoState)
        SELECT d.name, CONVERT(bit, d.is_read_committed_snapshot_on), CONVERT(tinyint, d.snapshot_isolation_state)
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_read_only = 0
          AND d.user_access = 0
          AND d.source_database_id IS NULL
          AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
          AND HAS_DBACCESS(d.name) = 1;
    END

    IF NOT EXISTS (SELECT 1 FROM #TargetDatabases)
    BEGIN
        SET @DatabaseQueried = N'None';
        SET @Finding         = N'No database found to be queried';
        SET @Score           = 0;
    END
    ELSE
    BEGIN
        DECLARE @CurrentDb   sysname;
        DECLARE @Sql         nvarchar(max);
        DECLARE @FailedDbs   nvarchar(max) = N'';

        DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName FROM #TargetDatabases ORDER BY DatabaseName;

        OPEN DbCursor;
        FETCH NEXT FROM DbCursor INTO @CurrentDb;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'
                    SELECT
                        @dbn,
                        s.name,
                        o.name,
                        o.type_desc,
                        CASE WHEN UPPER(m.definition) LIKE N''%ISOLATION LEVEL SERIALIZABLE%''     THEN 1 ELSE 0 END,
                        CASE WHEN UPPER(m.definition) LIKE N''%ISOLATION LEVEL REPEATABLE READ%''  THEN 1 ELSE 0 END,
                        CASE WHEN UPPER(m.definition) LIKE N''%ISOLATION LEVEL READ UNCOMMITTED%'' THEN 1 ELSE 0 END,
                        CASE WHEN UPPER(m.definition) LIKE N''%ISOLATION LEVEL SNAPSHOT%''         THEN 1 ELSE 0 END,
                        CASE WHEN UPPER(m.definition) LIKE N''%NOLOCK%''
                               OR UPPER(m.definition) LIKE N''%READUNCOMMITTED%''                  THEN 1 ELSE 0 END
                    FROM ' + QUOTENAME(@CurrentDb) + N'.sys.sql_modules AS m
                    INNER JOIN ' + QUOTENAME(@CurrentDb) + N'.sys.objects AS o
                        ON o.object_id = m.object_id
                    INNER JOIN ' + QUOTENAME(@CurrentDb) + N'.sys.schemas AS s
                        ON s.schema_id = o.schema_id
                    WHERE o.is_ms_shipped = 0
                      AND m.definition IS NOT NULL
                      AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'', ''V'');';

                INSERT INTO #IsolationModules
                (
                    DatabaseName, SchemaName, ObjectName, ObjectType,
                    UsesSerializable, UsesRepeatable, UsesReadUncommit, UsesSnapshot, UsesNoLockHint
                )
                EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @CurrentDb;

                UPDATE #TargetDatabases SET Scanned = 1 WHERE DatabaseName = @CurrentDb;
            END TRY
            BEGIN CATCH
                SET @FailedDbs = @FailedDbs
                               + CASE WHEN @FailedDbs = N'' THEN N'' ELSE N', ' END
                               + @CurrentDb;
            END CATCH;

            FETCH NEXT FROM DbCursor INTO @CurrentDb;
        END

        CLOSE DbCursor;
        DEALLOCATE DbCursor;

        DECLARE @DbCount          int = 0;
        DECLARE @ScannedCount     int = 0;
        DECLARE @TotalModules     int = 0;
        DECLARE @SerializableCnt  int = 0;
        DECLARE @RepeatableCnt    int = 0;
        DECLARE @ReadUncommitCnt  int = 0;
        DECLARE @SnapshotSetCnt   int = 0;
        DECLARE @NoLockCnt        int = 0;
        DECLARE @RcsiOffCount     int = 0;

        SELECT
            @DbCount      = COUNT(*),
            @ScannedCount = SUM(CASE WHEN Scanned = 1 THEN 1 ELSE 0 END),
            @RcsiOffCount = SUM(CASE WHEN RcsiOn = 0 AND SnapshotIsoState <> 1 THEN 1 ELSE 0 END)
        FROM #TargetDatabases;

        SELECT
            @TotalModules    = COUNT(*),
            @SerializableCnt = SUM(CASE WHEN UsesSerializable = 1 THEN 1 ELSE 0 END),
            @RepeatableCnt   = SUM(CASE WHEN UsesRepeatable   = 1 THEN 1 ELSE 0 END),
            @ReadUncommitCnt = SUM(CASE WHEN UsesReadUncommit = 1 THEN 1 ELSE 0 END),
            @SnapshotSetCnt  = SUM(CASE WHEN UsesSnapshot     = 1 THEN 1 ELSE 0 END),
            @NoLockCnt       = SUM(CASE WHEN UsesNoLockHint   = 1 THEN 1 ELSE 0 END)
        FROM #IsolationModules;

        SET @TotalModules    = ISNULL(@TotalModules, 0);
        SET @SerializableCnt = ISNULL(@SerializableCnt, 0);
        SET @RepeatableCnt   = ISNULL(@RepeatableCnt, 0);
        SET @ReadUncommitCnt = ISNULL(@ReadUncommitCnt, 0);
        SET @SnapshotSetCnt  = ISNULL(@SnapshotSetCnt, 0);
        SET @NoLockCnt       = ISNULL(@NoLockCnt, 0);
        SET @RcsiOffCount    = ISNULL(@RcsiOffCount, 0);
        SET @ScannedCount    = ISNULL(@ScannedCount, 0);

        -- Databases that lean on dirty-read hints while no row-versioning isolation is enabled.
        DECLARE @NoLockWithoutRcsi int = 0;
        SELECT @NoLockWithoutRcsi = COUNT(DISTINCT t.DatabaseName)
        FROM #TargetDatabases AS t
        INNER JOIN #IsolationModules AS im
            ON im.DatabaseName = t.DatabaseName
           AND im.UsesNoLockHint = 1
        WHERE t.RcsiOn = 0
          AND t.SnapshotIsoState <> 1;

        SET @DatabaseQueried = N'';
        SELECT @DatabaseQueried = @DatabaseQueried
                                + CASE WHEN @DatabaseQueried = N'' THEN N'' ELSE N', ' END
                                + DatabaseName
        FROM #TargetDatabases
        ORDER BY DatabaseName;

        IF @DatabaseQueried = N''
            SET @DatabaseQueried = N'None';

        DECLARE @SerializableList nvarchar(max) = N'';
        SELECT TOP (5)
               @SerializableList = @SerializableList
                                 + CASE WHEN @SerializableList = N'' THEN N'' ELSE N', ' END
                                 + DatabaseName + N'.' + SchemaName + N'.' + ObjectName
        FROM #IsolationModules
        WHERE UsesSerializable = 1
        ORDER BY DatabaseName, SchemaName, ObjectName;

        DECLARE @RepeatableList nvarchar(max) = N'';
        SELECT TOP (5)
               @RepeatableList = @RepeatableList
                               + CASE WHEN @RepeatableList = N'' THEN N'' ELSE N', ' END
                               + DatabaseName + N'.' + SchemaName + N'.' + ObjectName
        FROM #IsolationModules
        WHERE UsesRepeatable = 1
        ORDER BY DatabaseName, SchemaName, ObjectName;

        DECLARE @NoLockList nvarchar(max) = N'';
        SELECT TOP (5)
               @NoLockList = @NoLockList
                           + CASE WHEN @NoLockList = N'' THEN N'' ELSE N', ' END
                           + DatabaseName + N'.' + SchemaName + N'.' + ObjectName
        FROM #IsolationModules
        WHERE UsesNoLockHint = 1
        ORDER BY DatabaseName, SchemaName, ObjectName;

        DECLARE @RcsiOffList nvarchar(max) = N'';
        SELECT TOP (5)
               @RcsiOffList = @RcsiOffList
                            + CASE WHEN @RcsiOffList = N'' THEN N'' ELSE N', ' END
                            + DatabaseName
        FROM #TargetDatabases
        WHERE RcsiOn = 0 AND SnapshotIsoState <> 1
        ORDER BY DatabaseName;

        SET @Finding =
            N'Examined ' + CONVERT(nvarchar(20), @ScannedCount) + N' of '
            + CONVERT(nvarchar(20), @DbCount) + N' user database(s) ('
            + CASE WHEN @IsAzureSqlDb = 1 THEN N'Azure SQL Database - current database only' ELSE N'SQL Server' END
            + N') covering ' + CONVERT(nvarchar(20), @TotalModules) + N' user T-SQL module(s): '
            + CONVERT(nvarchar(20), @SerializableCnt) + N' set SERIALIZABLE, '
            + CONVERT(nvarchar(20), @RepeatableCnt)   + N' set REPEATABLE READ, '
            + CONVERT(nvarchar(20), @ReadUncommitCnt) + N' set READ UNCOMMITTED, '
            + CONVERT(nvarchar(20), @SnapshotSetCnt)  + N' set SNAPSHOT, '
            + CONVERT(nvarchar(20), @NoLockCnt)       + N' contain NOLOCK/READUNCOMMITTED hints. '
            + CONVERT(nvarchar(20), @RcsiOffCount)    + N' database(s) have neither RCSI nor ALLOW_SNAPSHOT_ISOLATION enabled.';

        IF @RcsiOffList <> N''
            SET @Finding = @Finding + N' No row-versioning isolation in: ' + @RcsiOffList + N'.';

        IF @SerializableList <> N''
            SET @Finding = @Finding + N' SERIALIZABLE examples: ' + @SerializableList + N'.';

        IF @RepeatableList <> N''
            SET @Finding = @Finding + N' REPEATABLE READ examples: ' + @RepeatableList + N'.';

        IF @NoLockList <> N''
            SET @Finding = @Finding + N' NOLOCK/READUNCOMMITTED examples: ' + @NoLockList + N'.';

        IF @FailedDbs <> N''
            SET @Finding = @Finding + N' Databases that could not be read: ' + @FailedDbs + N'.';

        IF @TotalModules = 0
            SET @Finding = @Finding + N' No user-defined T-SQL modules were found, so the assessment rests on the database-level snapshot settings only.';

        SET @Finding = @Finding + N' Note: module text is matched literally, so occurrences inside comments are counted and warrant a manual read of the listed objects.';

        IF @SerializableCnt > 0
        BEGIN
            SET @Score = 1;
            SET @Finding = @Finding
                + N' Verdict: one or more modules explicitly escalate to SERIALIZABLE, the most restrictive isolation level.';
        END
        ELSE IF @RepeatableCnt > 0 OR ISNULL(@NoLockWithoutRcsi, 0) > 0
        BEGIN
            SET @Score = 2;
            SET @Finding = @Finding
                + N' Verdict: no SERIALIZABLE usage, but isolation handling is not optimal - REPEATABLE READ is used and/or dirty-read hints compensate for RCSI/snapshot isolation being disabled.';
        END
        ELSE
        BEGIN
            SET @Score = 3;
            SET @Finding = @Finding
                + N' Verdict: no unnecessary SERIALIZABLE or REPEATABLE READ escalation, and row-versioning isolation is enabled or dirty-read hints are not relied upon.';
        END
    END
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'DbCursor') >= 0
    BEGIN
        CLOSE DbCursor;
        DEALLOCATE DbCursor;
    END

    SET @Score   = 0;
    SET @Finding = N'Unable to determine transaction isolation level usage. Error '
                 + CONVERT(nvarchar(20), ERROR_NUMBER()) + N': ' + ERROR_MESSAGE();

    IF @DatabaseQueried IS NULL OR @DatabaseQueried = N''
        SET @DatabaseQueried = N'None';
END CATCH;

IF OBJECT_ID('tempdb..#IsolationModules') IS NOT NULL DROP TABLE #IsolationModules;
IF OBJECT_ID('tempdb..#TargetDatabases') IS NOT NULL DROP TABLE #TargetDatabases;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;