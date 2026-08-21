/*
    Checklist Item : 7.2.3 - Audit trail for changes to financial-relevant data
    Scope          : DATABASE
    Mode           : READ-ONLY (catalog/DMV reads; the only writes are INSERTs into local temp tables)
    Purpose        : Determine, for every qualifying online user database, whether changes to
                     user data are captured by a durable audit trail (SQL Server Audit DML
                     actions, Change Data Capture or system-versioned temporal tables) or only
                     by weaker mechanisms (DML triggers, change tracking), and how much of the
                     user-table surface is covered.
*/
SET NOCOUNT ON;

DECLARE @Result          nvarchar(20);
DECLARE @Score           int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding         nvarchar(max) = N'No database found to be queried';

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));   -- 5 = Azure SQL Database
DECLARE @MajorVersion  int = TRY_CONVERT(int, PARSENAME(CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')), 4));
DECLARE @SupportsTemporal bit = CASE WHEN @EngineEdition IN (5, 8) OR ISNULL(@MajorVersion, 0) >= 13 THEN 1 ELSE 0 END;

/* Server-level audit run state: an enabled audit specification writes nothing without a started audit. */
DECLARE @RunningServerAudits int = NULL;   -- NULL = not determinable
IF @EngineEdition <> 5 AND OBJECT_ID('sys.dm_server_audit_status') IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC sp_executesql
             N'SELECT @c = COUNT(*) FROM sys.dm_server_audit_status WHERE status_desc = ''STARTED'';',
             N'@c int OUTPUT', @c = @RunningServerAudits OUTPUT;
    END TRY
    BEGIN CATCH
        SET @RunningServerAudits = NULL;
    END CATCH
END

IF OBJECT_ID('tempdb..#DbList')    IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Covered')   IS NOT NULL DROP TABLE #Covered;
IF OBJECT_ID('tempdb..#DbMetrics') IS NOT NULL DROP TABLE #DbMetrics;

CREATE TABLE #DbList
(
    DbName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #Covered
(
    DbName    sysname      NOT NULL,
    object_id int          NOT NULL,
    mechanism nvarchar(40) NOT NULL
);

CREATE TABLE #DbMetrics
(
    DbName            sysname NOT NULL PRIMARY KEY,
    UserTables        int NOT NULL,
    AuditSpecs        int NOT NULL,
    AuditSpecsEnabled int NOT NULL,
    DmlDbScope        int NOT NULL,
    CdcEnabled        int NOT NULL,
    CtEnabled         int NOT NULL,
    TriggerCount      int NOT NULL
);

/* ---------- 1. Qualifying user databases ---------- */
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0                     -- ONLINE only
      AND d.source_database_id IS NULL    -- exclude database snapshots
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

/* ---------- 2. Per-database collection (temp-table INSERTs only) ---------- */
DECLARE @Db sysname, @Q nvarchar(300), @Sql nvarchar(max);
DECLARE @HasCdcTables bit, @HasCtTables bit, @HasDbScopeDml int;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #DbList ORDER BY DbName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Q = QUOTENAME(@Db);
    SET @HasCdcTables = CASE WHEN OBJECT_ID(@Q + N'.cdc.change_tables') IS NOT NULL THEN 1 ELSE 0 END;
    SET @HasCtTables  = CASE WHEN OBJECT_ID(@Q + N'.sys.change_tracking_tables') IS NOT NULL THEN 1 ELSE 0 END;

    BEGIN TRY
        /* 2a. Base metrics: user tables, audit specifications, CDC/CT flags, trigger count. */
        SET @Sql = N'
            INSERT INTO #DbMetrics (DbName, UserTables, AuditSpecs, AuditSpecsEnabled, DmlDbScope,
                                    CdcEnabled, CtEnabled, TriggerCount)
            SELECT
                @dbn,
                (SELECT COUNT(*) FROM ' + @Q + N'.sys.tables AS t
                  WHERE t.type = ''U'' AND t.is_ms_shipped = 0),
                (SELECT COUNT(*) FROM ' + @Q + N'.sys.database_audit_specifications AS s),
                (SELECT ISNULL(SUM(CASE WHEN s.is_state_enabled = 1 THEN 1 ELSE 0 END), 0)
                   FROM ' + @Q + N'.sys.database_audit_specifications AS s),
                (SELECT COUNT(*)
                   FROM ' + @Q + N'.sys.database_audit_specification_details AS d
                   INNER JOIN ' + @Q + N'.sys.database_audit_specifications AS s
                           ON s.database_specification_id = d.database_specification_id
                  WHERE s.is_state_enabled = 1
                    AND d.audit_action_name IN (''INSERT'', ''UPDATE'', ''DELETE'')
                    AND d.class_desc IN (''DATABASE'', ''SCHEMA'')),
                (SELECT ISNULL(MAX(CONVERT(int, db.is_cdc_enabled)), 0)
                   FROM sys.databases AS db WHERE db.name = @dbn),
                (SELECT COUNT(*)
                   FROM sys.change_tracking_databases AS ctd
                   INNER JOIN sys.databases AS db ON db.database_id = ctd.database_id
                  WHERE db.name = @dbn),
                (SELECT COUNT(*)
                   FROM ' + @Q + N'.sys.triggers AS tr
                   INNER JOIN ' + @Q + N'.sys.tables AS t ON t.object_id = tr.parent_id
                  WHERE tr.parent_class = 1 AND tr.is_disabled = 0 AND tr.is_ms_shipped = 0
                    AND t.type = ''U'' AND t.is_ms_shipped = 0);';

        EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;

        /* 2b. Tables covered by an object-scoped DML audit specification. */
        SET @Sql = N'
            INSERT INTO #Covered (DbName, object_id, mechanism)
            SELECT DISTINCT @dbn, d.major_id, N''AuditSpec''
            FROM ' + @Q + N'.sys.database_audit_specification_details AS d
            INNER JOIN ' + @Q + N'.sys.database_audit_specifications AS s
                    ON s.database_specification_id = d.database_specification_id
            INNER JOIN ' + @Q + N'.sys.tables AS t
                    ON t.object_id = d.major_id
            WHERE s.is_state_enabled = 1
              AND d.audit_action_name IN (''INSERT'', ''UPDATE'', ''DELETE'')
              AND d.class_desc = ''OBJECT''
              AND t.type = ''U'' AND t.is_ms_shipped = 0;';

        EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;

        /* 2c. A database/schema-scoped DML audit action covers every user table. */
        SET @HasDbScopeDml = ISNULL((SELECT m.DmlDbScope FROM #DbMetrics AS m WHERE m.DbName = @Db), 0);

        IF @HasDbScopeDml > 0
        BEGIN
            SET @Sql = N'
                INSERT INTO #Covered (DbName, object_id, mechanism)
                SELECT @dbn, t.object_id, N''AuditSpecDbScope''
                FROM ' + @Q + N'.sys.tables AS t
                WHERE t.type = ''U'' AND t.is_ms_shipped = 0;';

            EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;
        END

        /* 2d. Change Data Capture capture instances. */
        IF @HasCdcTables = 1
        BEGIN
            SET @Sql = N'
                INSERT INTO #Covered (DbName, object_id, mechanism)
                SELECT DISTINCT @dbn, ct.source_object_id, N''CDC''
                FROM ' + @Q + N'.cdc.change_tables AS ct
                WHERE ct.source_object_id IS NOT NULL;';

            EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;
        END

        /* 2e. Change tracking (weak: records that a row changed, not the changed values). */
        IF @HasCtTables = 1
        BEGIN
            SET @Sql = N'
                INSERT INTO #Covered (DbName, object_id, mechanism)
                SELECT DISTINCT @dbn, ctt.object_id, N''ChangeTracking''
                FROM ' + @Q + N'.sys.change_tracking_tables AS ctt;';

            EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;
        END

        /* 2f. System-versioned temporal tables (SQL Server 2016+ / Azure SQL). */
        IF @SupportsTemporal = 1
        BEGIN
            SET @Sql = N'
                INSERT INTO #Covered (DbName, object_id, mechanism)
                SELECT @dbn, t.object_id, N''Temporal''
                FROM ' + @Q + N'.sys.tables AS t
                WHERE t.type = ''U'' AND t.is_ms_shipped = 0 AND t.temporal_type = 2;';

            EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;
        END

        /* 2g. Enabled DML triggers on user tables (weak evidence of a hand-rolled audit trail). */
        SET @Sql = N'
            INSERT INTO #Covered (DbName, object_id, mechanism)
            SELECT DISTINCT @dbn, tr.parent_id, N''DmlTrigger''
            FROM ' + @Q + N'.sys.triggers AS tr
            INNER JOIN ' + @Q + N'.sys.tables AS t ON t.object_id = tr.parent_id
            WHERE tr.parent_class = 1 AND tr.is_disabled = 0 AND tr.is_ms_shipped = 0
              AND t.type = ''U'' AND t.is_ms_shipped = 0;';

        EXEC sp_executesql @Sql, N'@dbn sysname', @dbn = @Db;
    END TRY
    BEGIN CATCH
        /* Unreadable database (permissions, recovery/offline race): skip it, partial data is tolerated. */
        SET @Sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* ---------- 3. Per-database coverage and scoring ---------- */
IF NOT EXISTS (SELECT 1 FROM #DbMetrics)
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    DECLARE @Scored TABLE
    (
        DbName         sysname       NOT NULL,
        UserTables     int           NOT NULL,
        StrongCovered  int           NOT NULL,
        AnyCovered     int           NOT NULL,
        StrongPct      decimal(5,1)  NOT NULL,
        Orphaned       bit           NOT NULL,
        DbScore        int           NOT NULL
    );

    INSERT INTO @Scored (DbName, UserTables, StrongCovered, AnyCovered, StrongPct, Orphaned, DbScore)
    SELECT
        m.DbName,
        m.UserTables,
        x.StrongCovered,
        x.AnyCovered,
        x.StrongPct,
        x.Orphaned,
        CASE
            WHEN m.UserTables = 0 THEN 3
            WHEN x.StrongPct >= 90.0 AND x.Orphaned = 0 THEN 3
            WHEN x.StrongPct >= 90.0 AND x.Orphaned = 1 THEN 2
            WHEN x.StrongPct >= 50.0 THEN 2
            WHEN x.AnyCovered > 0 THEN 1
            ELSE 0
        END
    FROM #DbMetrics AS m
    CROSS APPLY
    (
        SELECT
            StrongCovered = sc.StrongCovered,
            AnyCovered    = ac.AnyCovered,
            StrongPct     = CASE WHEN m.UserTables > 0
                                 THEN CONVERT(decimal(5,1), 100.0 * sc.StrongCovered / m.UserTables)
                                 ELSE CONVERT(decimal(5,1), 0) END,
            Orphaned      = CASE WHEN m.AuditSpecsEnabled > 0
                                      AND @RunningServerAudits IS NOT NULL
                                      AND @RunningServerAudits = 0
                                 THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END
        FROM (SELECT StrongCovered = COUNT(DISTINCT c.object_id)
                FROM #Covered AS c
               WHERE c.DbName = m.DbName
                 AND c.mechanism IN (N'Temporal', N'CDC', N'AuditSpec', N'AuditSpecDbScope')) AS sc
        CROSS JOIN (SELECT AnyCovered = COUNT(DISTINCT c.object_id)
                      FROM #Covered AS c
                     WHERE c.DbName = m.DbName) AS ac
    ) AS x;

    SELECT @Score = MIN(s.DbScore) FROM @Scored AS s;

    SELECT @DatabaseQueried = STUFF((SELECT N', ' + s.DbName
                                     FROM @Scored AS s
                                     ORDER BY s.DbName
                                     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    DECLARE @DbTotal     int = (SELECT COUNT(*) FROM @Scored);
    DECLARE @DbCompliant int = (SELECT COUNT(*) FROM @Scored WHERE DbScore >= 2);
    DECLARE @DbNone      int = (SELECT COUNT(*) FROM @Scored WHERE DbScore = 0);

    DECLARE @Worst nvarchar(max) =
        ISNULL(STUFF((SELECT TOP (15) N'; ' + s.DbName
                             + N' (score ' + CONVERT(nvarchar(10), s.DbScore)
                             + N', durable coverage ' + CONVERT(nvarchar(20), s.StrongCovered)
                             + N'/' + CONVERT(nvarchar(20), s.UserTables)
                             + N' = ' + CONVERT(nvarchar(20), s.StrongPct) + N'%'
                             + N', any coverage ' + CONVERT(nvarchar(20), s.AnyCovered)
                             + CASE WHEN s.Orphaned = 1 THEN N', audit spec enabled but no server audit started' ELSE N'' END
                             + N')'
                      FROM @Scored AS s
                      WHERE s.DbScore < 2
                      ORDER BY s.DbScore, s.DbName
                      FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

    DECLARE @Totals nvarchar(max) =
        N'Mechanism totals across queried databases: '
      + CONVERT(nvarchar(20), (SELECT ISNULL(SUM(AuditSpecsEnabled), 0) FROM #DbMetrics)) + N' enabled database audit specification(s), '
      + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #DbMetrics WHERE DmlDbScope > 0)) + N' database(s) with database/schema-scoped DML audit actions, '
      + CONVERT(nvarchar(20), (SELECT COUNT(DISTINCT CONVERT(nvarchar(300), c.DbName) + N'|' + CONVERT(nvarchar(20), c.object_id))
                                 FROM #Covered AS c WHERE c.mechanism = N'AuditSpec')) + N' object-scoped audited table(s), '
      + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #DbMetrics WHERE CdcEnabled = 1)) + N' CDC-enabled database(s) covering '
      + CONVERT(nvarchar(20), (SELECT COUNT(DISTINCT CONVERT(nvarchar(300), c.DbName) + N'|' + CONVERT(nvarchar(20), c.object_id))
                                 FROM #Covered AS c WHERE c.mechanism = N'CDC')) + N' table(s), '
      + CONVERT(nvarchar(20), (SELECT COUNT(DISTINCT CONVERT(nvarchar(300), c.DbName) + N'|' + CONVERT(nvarchar(20), c.object_id))
                                 FROM #Covered AS c WHERE c.mechanism = N'Temporal')) + N' system-versioned temporal table(s), '
      + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #DbMetrics WHERE CtEnabled > 0)) + N' change-tracking-enabled database(s) covering '
      + CONVERT(nvarchar(20), (SELECT COUNT(DISTINCT CONVERT(nvarchar(300), c.DbName) + N'|' + CONVERT(nvarchar(20), c.object_id))
                                 FROM #Covered AS c WHERE c.mechanism = N'ChangeTracking')) + N' table(s), and '
      + CONVERT(nvarchar(20), (SELECT ISNULL(SUM(TriggerCount), 0) FROM #DbMetrics)) + N' enabled DML trigger(s) on '
      + CONVERT(nvarchar(20), (SELECT COUNT(DISTINCT CONVERT(nvarchar(300), c.DbName) + N'|' + CONVERT(nvarchar(20), c.object_id))
                                 FROM #Covered AS c WHERE c.mechanism = N'DmlTrigger')) + N' table(s). '
      + N'Started server audits: '
      + CASE WHEN @RunningServerAudits IS NULL THEN N'not determinable on this edition/permission level'
             ELSE CONVERT(nvarchar(20), @RunningServerAudits) END + N'.';

    SET @Finding =
        CONVERT(nvarchar(20), @DbCompliant) + N' of ' + CONVERT(nvarchar(20), @DbTotal)
      + N' queried user database(s) have a durable audit trail over the majority of their user tables; '
      + CONVERT(nvarchar(20), @DbNone) + N' database(s) have no change-audit mechanism at all. '
      + @Totals
      + N' Databases below the durable-coverage bar: ' + @Worst + N'. '
      + CASE WHEN @Score >= 2
             THEN N'Every queried database retains a durable record of data changes; confirm the retention period and that the audited tables are the financial-relevant ones.'
             ELSE N'At least one queried database has no durable audit trail for data changes, so INSERT/UPDATE/DELETE activity against financial-relevant data cannot be reconstructed. Enable SQL Server Audit with INSERT/UPDATE/DELETE actions (backed by a started server audit), CDC, or system-versioned temporal tables on the tables holding financial data.'
        END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbList')    IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Covered')   IS NOT NULL DROP TABLE #Covered;
IF OBJECT_ID('tempdb..#DbMetrics') IS NOT NULL DROP TABLE #DbMetrics;