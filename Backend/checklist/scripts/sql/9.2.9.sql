SET NOCOUNT ON;

DECLARE @EngineEdition      INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried    NVARCHAR(128) = N'SERVER';
DECLARE @Result             NVARCHAR(20);
DECLARE @Score              INT = 0;
DECLARE @Finding            NVARCHAR(4000) = N'';
DECLARE @Done               BIT = 0;

DECLARE @IsHadrEnabled      INT = 0;
DECLARE @MajorVersion       INT = ISNULL(TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT), 0);
DECLARE @AGCount            INT = 0;
DECLARE @UnhealthyReplicas  INT = 0;
DECLARE @NotSyncDbs         INT = 0;
DECLARE @QuorumState        NVARCHAR(128) = N'UNKNOWN';
DECLARE @UnhealthyList      NVARCHAR(2000) = N'none';
DECLARE @XeRunning          INT = 0;
DECLARE @AGAlerts           INT = 0;
DECLARE @AGAlertsNotified   INT = 0;
DECLARE @SevAlerts          INT = 0;
DECLARE @EnabledOperators   INT = 0;
DECLARE @AgentRunning       INT = -1;
DECLARE @Sql                NVARCHAR(MAX);

CREATE TABLE #HadrState
(
    AGCount           INT,
    UnhealthyReplicas INT,
    NotSyncDbs        INT,
    QuorumState       NVARCHAR(128),
    UnhealthyList     NVARCHAR(2000)
);

IF @EngineEdition IN (5, 6, 11)
BEGIN
    SET @Done  = 1;
    SET @Score = 3;
    SET @Finding = N'Not applicable: platform-managed Azure SQL service (EngineEdition '
                 + CAST(@EngineEdition AS NVARCHAR(10))
                 + N'). Availability Group / cluster health and replica synchronization are monitored and remediated by the Azure platform SLA; no customer-configurable Always On alerting surface (SQL Agent alerts, operators, AlwaysOn_health session) exists on this engine edition.';
END;

IF @Done = 0
BEGIN
    SET @IsHadrEnabled = ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS INT), 0);

    IF @IsHadrEnabled = 1 AND @MajorVersion >= 11
    BEGIN
        SET @Sql = N'
        INSERT INTO #HadrState (AGCount, UnhealthyReplicas, NotSyncDbs, QuorumState, UnhealthyList)
        SELECT
            (SELECT COUNT(*) FROM sys.availability_groups),
            (SELECT COUNT(*)
               FROM sys.dm_hadr_availability_replica_states rs
              WHERE ISNULL(rs.synchronization_health_desc, N''NOT_HEALTHY'') <> N''HEALTHY''
                 OR ISNULL(rs.connected_state_desc, N''CONNECTED'') = N''DISCONNECTED''),
            (SELECT COUNT(*)
               FROM sys.dm_hadr_database_replica_states drs
              WHERE ISNULL(drs.synchronization_state_desc, N''NOT SYNCHRONIZING'')
                    NOT IN (N''SYNCHRONIZED'', N''SYNCHRONIZING'')),
            ISNULL((SELECT TOP (1) c.quorum_state_desc FROM sys.dm_hadr_cluster c), N''NO WSFC CLUSTER''),
            ISNULL(STUFF((SELECT TOP (5)
                                 N''; '' + ISNULL(ar.replica_server_name, N''(unknown replica)'')
                               + N'' [health='' + ISNULL(rs.synchronization_health_desc, N''UNKNOWN'')
                               + N'', conn='' + ISNULL(rs.connected_state_desc, N''UNKNOWN'')
                               + N'', role='' + ISNULL(rs.role_desc, N''UNKNOWN'') + N'']''
                            FROM sys.dm_hadr_availability_replica_states rs
                            INNER JOIN sys.availability_replicas ar
                                    ON ar.replica_id = rs.replica_id
                           WHERE ISNULL(rs.synchronization_health_desc, N''NOT_HEALTHY'') <> N''HEALTHY''
                              OR ISNULL(rs.connected_state_desc, N''CONNECTED'') = N''DISCONNECTED''
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(2000)''), 1, 2, N''''), N''none'');';

        EXEC sys.sp_executesql @Sql;

        SELECT TOP (1)
               @AGCount           = h.AGCount,
               @UnhealthyReplicas = h.UnhealthyReplicas,
               @NotSyncDbs        = h.NotSyncDbs,
               @QuorumState       = h.QuorumState,
               @UnhealthyList     = h.UnhealthyList
          FROM #HadrState h;
    END;

    IF @IsHadrEnabled = 0 OR @AGCount = 0
    BEGIN
        SET @Done  = 1;
        SET @Score = 3;
        SET @Finding = N'Not applicable: '
            + CASE WHEN @IsHadrEnabled = 0
                   THEN N'the Always On Availability Groups feature is not enabled on this instance (SERVERPROPERTY(''IsHadrEnabled'') = 0)'
                   ELSE N'the Always On feature is enabled but no Availability Groups are configured (sys.availability_groups returned 0 rows)'
              END
            + N'. There is no AG or replica synchronization state to monitor on this instance.';
    END;
END;

IF @Done = 0
BEGIN
    SELECT @XeRunning = COUNT(*)
      FROM sys.dm_xe_sessions s
     WHERE s.name = N'AlwaysOn_health';

    SET @Sql = N'
    SELECT
        @pAGAlerts         = ISNULL(SUM(CASE WHEN a.IsAgSpecific = 1 THEN 1 ELSE 0 END), 0),
        @pAGAlertsNotified = ISNULL(SUM(CASE WHEN a.IsAgSpecific = 1 AND a.HasNotification = 1 THEN 1 ELSE 0 END), 0),
        @pSevAlerts        = ISNULL(SUM(CASE WHEN a.IsAgSpecific = 0 THEN 1 ELSE 0 END), 0)
    FROM (
        SELECT
            CASE
                WHEN sa.message_id IN (1480, 19406, 19407, 19419, 19421, 35201, 35202, 35206, 35250,
                                       35254, 35262, 35264, 35265, 35266, 35273, 35274, 35276, 35278,
                                       41091, 41131, 41142, 41404, 41405, 41406, 41414)
                     OR ISNULL(sa.performance_condition, N'''') LIKE N''%Replica%''
                     OR ISNULL(sa.performance_condition, N'''') LIKE N''%Availability%''
                     OR ISNULL(sa.event_description_keyword, N'''') LIKE N''%availability group%''
                     OR ISNULL(sa.event_description_keyword, N'''') LIKE N''%replica%''
                     OR ISNULL(sa.event_description_keyword, N'''') LIKE N''%synchroniz%''
                     OR ISNULL(sa.name, N'''') LIKE N''%availability group%''
                     OR ISNULL(sa.name, N'''') LIKE N''%always on%''
                     OR ISNULL(sa.name, N'''') LIKE N''%alwayson%''
                THEN 1 ELSE 0
            END AS IsAgSpecific,
            CASE WHEN EXISTS (SELECT 1
                                FROM msdb.dbo.sysnotifications sn
                                INNER JOIN msdb.dbo.sysoperators so
                                        ON so.id = sn.operator_id
                                       AND so.enabled = 1
                               WHERE sn.alert_id = sa.id)
                 THEN 1 ELSE 0
            END AS HasNotification
        FROM msdb.dbo.sysalerts sa
        WHERE sa.enabled = 1
          AND (sa.message_id > 0 OR sa.severity BETWEEN 17 AND 25 OR sa.performance_condition IS NOT NULL)
    ) AS a;

    SELECT @pEnabledOperators = COUNT(*) FROM msdb.dbo.sysoperators WHERE enabled = 1;';

    BEGIN TRY
        EXEC sys.sp_executesql
             @Sql,
             N'@pAGAlerts INT OUTPUT, @pAGAlertsNotified INT OUTPUT, @pSevAlerts INT OUTPUT, @pEnabledOperators INT OUTPUT',
             @pAGAlerts         = @AGAlerts         OUTPUT,
             @pAGAlertsNotified = @AGAlertsNotified OUTPUT,
             @pSevAlerts        = @SevAlerts        OUTPUT,
             @pEnabledOperators = @EnabledOperators OUTPUT;
    END TRY
    BEGIN CATCH
        SET @AGAlerts         = 0;
        SET @AGAlertsNotified = 0;
        SET @SevAlerts        = 0;
        SET @EnabledOperators = 0;
    END CATCH;

    SET @AGAlerts         = ISNULL(@AGAlerts, 0);
    SET @AGAlertsNotified = ISNULL(@AGAlertsNotified, 0);
    SET @SevAlerts        = ISNULL(@SevAlerts, 0);
    SET @EnabledOperators = ISNULL(@EnabledOperators, 0);

    IF EXISTS (SELECT 1 FROM sys.system_objects WHERE name = N'dm_server_services')
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @pAgentRunning = COUNT(*)
                           FROM sys.dm_server_services
                          WHERE servicename LIKE N''SQL Server Agent%''
                            AND status_desc = N''Running'';';
            EXEC sys.sp_executesql @Sql, N'@pAgentRunning INT OUTPUT', @pAgentRunning = @AgentRunning OUTPUT;
        END TRY
        BEGIN CATCH
            SET @AgentRunning = -1;
        END CATCH;
    END;

    DECLARE @ActiveAlerting  BIT = CASE WHEN @AGAlerts >= 1 AND @AGAlertsNotified >= 1 AND @EnabledOperators >= 1 THEN 1 ELSE 0 END;
    DECLARE @PartialAlerting BIT = CASE WHEN (@AGAlerts >= 1 OR @SevAlerts >= 1) THEN 1 ELSE 0 END;
    DECLARE @HealthyNow      BIT = CASE WHEN @UnhealthyReplicas = 0 AND @NotSyncDbs = 0 AND @QuorumState = N'NORMAL_QUORUM' THEN 1 ELSE 0 END;

    SET @Score = CASE
                    WHEN @ActiveAlerting = 1 AND @XeRunning = 1 AND @HealthyNow = 1 THEN 3
                    WHEN @ActiveAlerting = 1 THEN 2
                    WHEN @PartialAlerting = 1 THEN 1
                    ELSE 0
                 END;

    SET @Finding =
          N'Availability Groups configured: ' + CAST(@AGCount AS NVARCHAR(10))
        + N'. WSFC quorum state: ' + @QuorumState
        + N'. Replicas not HEALTHY or DISCONNECTED: ' + CAST(@UnhealthyReplicas AS NVARCHAR(10))
        + N'. Databases not SYNCHRONIZED/SYNCHRONIZING: ' + CAST(@NotSyncDbs AS NVARCHAR(10))
        + N'. Unhealthy replica detail: ' + @UnhealthyList
        + N'. AlwaysOn_health Extended Events session running: ' + CASE WHEN @XeRunning = 1 THEN N'YES' ELSE N'NO' END
        + N'. Enabled AG-specific SQL Agent alerts: ' + CAST(@AGAlerts AS NVARCHAR(10))
        + N' (notified to an enabled operator: ' + CAST(@AGAlertsNotified AS NVARCHAR(10)) + N')'
        + N'. Enabled generic severity 17-25 alerts: ' + CAST(@SevAlerts AS NVARCHAR(10))
        + N'. Enabled operators: ' + CAST(@EnabledOperators AS NVARCHAR(10))
        + N'. SQL Server Agent service running: '
        + CASE WHEN @AgentRunning > 0 THEN N'YES' WHEN @AgentRunning = 0 THEN N'NO' ELSE N'UNDETERMINED' END
        + N'. Assessment: '
        + CASE
            WHEN @Score = 3 THEN N'AG/replica health is currently sound and an active alerting path (AG-specific enabled alert notified to an enabled operator) plus the AlwaysOn_health diagnostic session are in place.'
            WHEN @Score = 2 THEN N'An AG alerting path with operator notification exists, but '
                 + CASE WHEN @XeRunning = 0 THEN N'the AlwaysOn_health Extended Events session is not running' ELSE N'' END
                 + CASE WHEN @XeRunning = 0 AND @HealthyNow = 0 THEN N' and ' ELSE N'' END
                 + CASE WHEN @HealthyNow = 0 THEN N'the current AG state shows unhealthy/not-synchronizing replicas or abnormal quorum' ELSE N'' END
                 + N'.'
            WHEN @Score = 1 THEN N'Alerting is only partially configured - AG-related or severity alerts exist but no AG-specific enabled alert is wired to a notification for an enabled operator, so unhealthy or not-synchronizing replicas would not reach anyone.'
            ELSE N'No enabled SQL Agent alerts cover Always On availability group failure conditions or high-severity errors, so replica health and synchronization failures are not alerted.'
          END
        + N' Note: alerting delivered exclusively by an external monitoring platform (SCOM, Zabbix, Datadog, Azure Monitor, etc.) is not visible to this instance-level query and should be confirmed manually.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #HadrState;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;