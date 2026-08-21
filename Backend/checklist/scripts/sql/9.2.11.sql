/* Checklist 9.2.11 - Backup preference configured (backups taken from the preferred / secondary
   replica where used) and validated across failover. READ-ONLY. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(64);
DECLARE @Score INT = 1;
DECLARE @Finding NVARCHAR(MAX) = N'';
DECLARE @DatabaseQueried NVARCHAR(256) = N'master';

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsHadrEnabled INT = ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS INT), 0);
DECLARE @ErrMsg NVARCHAR(2048) = NULL;
DECLARE @HistErr NVARCHAR(2048) = NULL;

CREATE TABLE #AG
(
    AGName SYSNAME NOT NULL,
    BackupPreference NVARCHAR(60) NULL
);

CREATE TABLE #Replica
(
    AGName SYSNAME NOT NULL,
    ReplicaServerName NVARCHAR(256) NULL,
    BackupPriority INT NULL,
    RoleDesc NVARCHAR(60) NULL
);

CREATE TABLE #AGDB
(
    AGName SYSNAME NOT NULL,
    DatabaseName SYSNAME NOT NULL
);

CREATE TABLE #BackupSrv
(
    DatabaseName SYSNAME NOT NULL,
    ServerName NVARCHAR(256) NULL,
    BackupCount INT NULL,
    LastBackup DATETIME NULL
);

CREATE TABLE #PrefJob
(
    StepCount INT NULL
);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = N'Engine edition is Azure SQL Database. Backups and replica placement are managed entirely by the platform and Availability Group backup preference is not user-configurable, so this control is not applicable to this instance.';
END
ELSE IF @IsHadrEnabled <> 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'SERVERPROPERTY(''IsHadrEnabled'') = 0. The AlwaysOn Availability Groups feature is not enabled on this instance, so no backup preference or preferred-replica routing applies (the "where used" condition of the control is not met).';
END
ELSE
BEGIN
    BEGIN TRY
        INSERT INTO #AG (AGName, BackupPreference)
        EXEC sp_executesql N'SELECT ag.name, ag.automated_backup_preference_desc
                             FROM sys.availability_groups AS ag;';

        INSERT INTO #Replica (AGName, ReplicaServerName, BackupPriority, RoleDesc)
        EXEC sp_executesql N'SELECT ag.name, ar.replica_server_name, ar.backup_priority, rs.role_desc
                             FROM sys.availability_groups AS ag
                             INNER JOIN sys.availability_replicas AS ar
                                 ON ar.group_id = ag.group_id
                             LEFT JOIN sys.dm_hadr_availability_replica_states AS rs
                                 ON rs.replica_id = ar.replica_id;';

        INSERT INTO #AGDB (AGName, DatabaseName)
        EXEC sp_executesql N'SELECT ag.name, adc.database_name
                             FROM sys.availability_groups AS ag
                             INNER JOIN sys.availability_databases_cluster AS adc
                                 ON adc.group_id = ag.group_id;';
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();
    END CATCH

    BEGIN TRY
        INSERT INTO #BackupSrv (DatabaseName, ServerName, BackupCount, LastBackup)
        EXEC sp_executesql N'SELECT bs.database_name, bs.server_name, COUNT(*), MAX(bs.backup_finish_date)
                             FROM msdb.dbo.backupset AS bs
                             WHERE bs.type IN (''D'', ''I'', ''L'')
                               AND bs.backup_finish_date >= DATEADD(DAY, -90, GETDATE())
                             GROUP BY bs.database_name, bs.server_name;';

        INSERT INTO #PrefJob (StepCount)
        EXEC sp_executesql N'SELECT COUNT(*)
                             FROM msdb.dbo.sysjobsteps AS js
                             WHERE js.command LIKE N''%fn_hadr_backup_is_preferred_replica%'';';

        SET @DatabaseQueried = N'master, msdb';
    END TRY
    BEGIN CATCH
        SET @HistErr = ERROR_MESSAGE();
    END CATCH

    DECLARE @AGCount INT = (SELECT COUNT(*) FROM #AG);
    DECLARE @NonePref INT = (SELECT COUNT(*) FROM #AG WHERE UPPER(ISNULL(BackupPreference, N'')) = N'NONE');
    DECLARE @AllZeroPriority INT = (SELECT COUNT(*)
                                    FROM #AG AS a
                                    WHERE NOT EXISTS (SELECT 1 FROM #Replica AS r
                                                      WHERE r.AGName = a.AGName
                                                        AND ISNULL(r.BackupPriority, 0) > 0));
    DECLARE @SecondaryPrefAGs INT = (SELECT COUNT(*) FROM #AG
                                     WHERE UPPER(ISNULL(BackupPreference, N'')) IN (N'SECONDARY', N'SECONDARY_ONLY'));
    DECLARE @AGDBTotal INT = (SELECT COUNT(*) FROM #AGDB);
    DECLARE @AGDBBackedUp INT = (SELECT COUNT(*)
                                 FROM #AGDB AS d
                                 WHERE EXISTS (SELECT 1 FROM #BackupSrv AS b WHERE b.DatabaseName = d.DatabaseName));
    DECLARE @AGDBMultiSrv INT = (SELECT COUNT(*)
                                 FROM (SELECT d.DatabaseName
                                       FROM #AGDB AS d
                                       INNER JOIN #BackupSrv AS b ON b.DatabaseName = d.DatabaseName
                                       GROUP BY d.DatabaseName
                                       HAVING COUNT(DISTINCT b.ServerName) > 1) AS x);
    DECLARE @PrefJobSteps INT = ISNULL((SELECT MAX(StepCount) FROM #PrefJob), 0);

    DECLARE @AGDetail NVARCHAR(MAX) =
        ISNULL(STUFF((SELECT N'; ' + a.AGName
                             + N' preference=' + ISNULL(a.BackupPreference, N'UNKNOWN')
                             + N' priorities=['
                             + ISNULL(STUFF((SELECT N', ' + ISNULL(r.ReplicaServerName, N'?')
                                                    + N'(' + ISNULL(r.RoleDesc, N'ROLE_UNKNOWN') + N')='
                                                    + CAST(ISNULL(r.BackupPriority, 0) AS NVARCHAR(10))
                                             FROM #Replica AS r
                                             WHERE r.AGName = a.AGName
                                             ORDER BY r.ReplicaServerName
                                             FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'no replicas')
                             + N']'
                      FROM #AG AS a
                      ORDER BY a.AGName
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'none');

    DECLARE @UnbackedList NVARCHAR(MAX) =
        ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                      FROM #AGDB AS d
                      WHERE NOT EXISTS (SELECT 1 FROM #BackupSrv AS b WHERE b.DatabaseName = d.DatabaseName)
                      ORDER BY d.DatabaseName
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'none');

    DECLARE @SourceDetail NVARCHAR(MAX) =
        ISNULL(STUFF((SELECT N'; ' + x.DatabaseName + N' backed up from ' + CAST(x.SrvCount AS NVARCHAR(10)) + N' server(s)'
                      FROM (SELECT d.DatabaseName, COUNT(DISTINCT b.ServerName) AS SrvCount
                            FROM #AGDB AS d
                            INNER JOIN #BackupSrv AS b ON b.DatabaseName = d.DatabaseName
                            GROUP BY d.DatabaseName) AS x
                      ORDER BY x.DatabaseName
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'no backup history in the last 90 days');

    IF @ErrMsg IS NOT NULL AND @AGCount = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Availability Group metadata could not be read (error: ' + @ErrMsg
                     + N'). VIEW SERVER STATE / VIEW ANY DEFINITION is required to evaluate the automated backup preference. Backup preference and failover validation must be reviewed manually.';
    END
    ELSE IF @AGCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'AlwaysOn is enabled but no Availability Groups exist on this instance (sys.availability_groups returned 0 rows), so no backup preference or preferred-replica routing is required. Control not applicable.';
    END
    ELSE IF @NonePref > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = CAST(@NonePref AS NVARCHAR(10)) + N' of ' + CAST(@AGCount AS NVARCHAR(10))
                     + N' Availability Group(s) have automated_backup_preference = NONE, so no preferred backup replica is defined. AG detail: ' + @AGDetail + N'.';
    END
    ELSE IF @AllZeroPriority > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = CAST(@AllZeroPriority AS NVARCHAR(10)) + N' of ' + CAST(@AGCount AS NVARCHAR(10))
                     + N' Availability Group(s) have backup_priority = 0 on every replica, which excludes all replicas from automated backups regardless of the configured preference. AG detail: ' + @AGDetail + N'.';
    END
    ELSE IF @HistErr IS NOT NULL
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Backup preference is configured on all ' + CAST(@AGCount AS NVARCHAR(10))
                     + N' Availability Group(s) (' + @AGDetail
                     + N'), but backup history in msdb could not be read (error: ' + @HistErr
                     + N'), so it could not be confirmed that backups were actually taken from the preferred replica across failover.';
    END
    ELSE IF @AGDBTotal = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Backup preference is configured (' + @AGDetail
                     + N') but no databases are joined to any Availability Group (sys.availability_databases_cluster returned 0 rows), so the preference has never been exercised and cannot be validated across failover.';
    END
    ELSE IF @AGDBBackedUp < @AGDBTotal
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Backup preference is configured (' + @AGDetail + N'), but only '
                     + CAST(@AGDBBackedUp AS NVARCHAR(10)) + N' of ' + CAST(@AGDBTotal AS NVARCHAR(10))
                     + N' AG database(s) have any backup recorded in msdb in the last 90 days. Databases with no recent backup: ' + @UnbackedList
                     + N'. The preferred-replica backup configuration is not producing backups for all AG databases.';
    END
    ELSE IF @AGDBMultiSrv = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Backup preference is configured and all ' + CAST(@AGDBTotal AS NVARCHAR(10))
                     + N' AG database(s) have recent backups (' + @AGDetail
                     + N'), but every AG database''s backups in the last 90 days originate from a single server (' + @SourceDetail
                     + N'). There is no evidence in msdb.dbo.backupset that backups followed the preferred replica across a failover; validate with a failover test.';
    END
    ELSE IF @SecondaryPrefAGs > 0 AND @PrefJobSteps = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@SecondaryPrefAGs AS NVARCHAR(10)) + N' Availability Group(s) prefer a secondary replica for backups ('
                     + @AGDetail + N') and backups exist from multiple servers (' + @SourceDetail
                     + N'), but no SQL Agent job step references sys.fn_hadr_backup_is_preferred_replica, so it could not be confirmed that the backup jobs honour the preference on every replica.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@AGCount AS NVARCHAR(10)) + N' Availability Group(s) have a backup preference other than NONE with at least one eligible replica ('
                     + @AGDetail + N'). All ' + CAST(@AGDBTotal AS NVARCHAR(10))
                     + N' AG database(s) have backups in the last 90 days and ' + CAST(@AGDBMultiSrv AS NVARCHAR(10))
                     + N' database(s) show backups taken from more than one server, evidencing that backups followed the preferred replica across a failover (' + @SourceDetail
                     + N'). ' + CAST(@PrefJobSteps AS NVARCHAR(10)) + N' Agent job step(s) reference sys.fn_hadr_backup_is_preferred_replica.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;