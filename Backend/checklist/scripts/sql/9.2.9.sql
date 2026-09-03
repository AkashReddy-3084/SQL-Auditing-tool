-- Checklist: AG / cluster health and replica synchronization state actively monitored - unhealthy or not-synchronizing replicas alerted
-- Scope: SERVER
-- Scoring: 3 = availability groups exist, every replica is HEALTHY, every database replica is SYNCHRONIZED or SYNCHRONIZING, and an enabled Agent alert covers AG errors; 2 = availability groups exist with an enabled AG alert or a running AlwaysOn_health session (or Azure SQL Database platform health monitoring); 1 = availability groups exist with no alert and no health session; 0 = no availability group or no health evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Availability group health and alerting evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Groups INT = 0;
DECLARE @Replicas INT = 0;
DECLARE @Unhealthy INT = 0;
DECLARE @NotSynchronising INT = 0;
DECLARE @UnhealthyNames NVARCHAR(400) = 'none';
DECLARE @Alerts INT = 0;
DECLARE @HealthSession INT = 0;
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: no availability group or cluster objects are exposed; replica health and synchronisation of the platform-managed quorum set are monitored by the service and surfaced through Azure Monitor outside this instance.';
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.dm_hadr_availability_replica_states') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = (SELECT COUNT(*) FROM sys.availability_groups),
       @r = (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states),
       @u = (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states
             WHERE ISNULL(synchronization_health_desc, ''NOT_HEALTHY'') <> ''HEALTHY''),
       @d = (SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states
             WHERE ISNULL(synchronization_state_desc, ''NOT SYNCHRONIZING'')
                   NOT IN (''SYNCHRONIZED'', ''SYNCHRONIZING'')),
       @n = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), ar.replica_server_name + '' ''
                           + ISNULL(rs.synchronization_health_desc, ''UNKNOWN'')), '', '')
                    FROM sys.dm_hadr_availability_replica_states AS rs
                    JOIN sys.availability_replicas AS ar ON ar.replica_id = rs.replica_id
                    WHERE ISNULL(rs.synchronization_health_desc, ''NOT_HEALTHY'') <> ''HEALTHY''), ''none'');';
            EXEC sp_executesql @Sql,
                 N'@a INT OUTPUT, @r INT OUTPUT, @u INT OUTPUT, @d INT OUTPUT, @n NVARCHAR(400) OUTPUT',
                 @a = @Groups OUTPUT, @r = @Replicas OUTPUT, @u = @Unhealthy OUTPUT,
                 @d = @NotSynchronising OUTPUT, @n = @UnhealthyNames OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Always On health state was not readable.';
    END CATCH

    BEGIN TRY
        SET @Sql = N'SELECT @x = COUNT(*)
FROM msdb.dbo.sysalerts AS a
WHERE a.enabled = 1
  AND (a.message_id IN (35264, 35265, 41404, 41405, 41406, 41414, 41421)
       OR a.name LIKE ''%availab%'' OR a.name LIKE ''%replica%'' OR a.name LIKE ''%always on%'');';
        EXEC sp_executesql @Sql, N'@x INT OUTPUT', @x = @Alerts OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' msdb alert definitions were not readable.';
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('sys.dm_xe_sessions') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @h = COUNT(*) FROM sys.dm_xe_sessions WHERE name = ''AlwaysOn_health'';';
            EXEC sp_executesql @Sql, N'@h INT OUTPUT', @h = @HealthSession OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' Extended Events session state was not readable.';
    END CATCH

    SET @Groups = ISNULL(@Groups, 0);
    SET @Replicas = ISNULL(@Replicas, 0);
    SET @Unhealthy = ISNULL(@Unhealthy, 0);
    SET @NotSynchronising = ISNULL(@NotSynchronising, 0);
    SET @Alerts = ISNULL(@Alerts, 0);
    SET @HealthSession = ISNULL(@HealthSession, 0);
    SET @UnhealthyNames = ISNULL(@UnhealthyNames, 'none');

    SET @Score = CASE
        WHEN @Groups > 0 AND @Unhealthy = 0 AND @NotSynchronising = 0 AND @Alerts > 0 THEN 3
        WHEN @Groups > 0 AND (@Alerts > 0 OR @HealthSession > 0) THEN 2
        WHEN @Groups > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Availability groups = ', @Groups, ', replica states = ', @Replicas,
        ', replicas not HEALTHY = ', @Unhealthy, ' (', @UnhealthyNames,
        '), database replicas not synchronised or synchronising = ', @NotSynchronising,
        '; enabled Agent alerts covering AG health = ', @Alerts,
        '; running AlwaysOn_health Extended Events sessions = ', @HealthSession, '.',
        CASE WHEN @Groups > 0 AND @Alerts = 0 AND @HealthSession = 0
             THEN ' No alert or health session would raise an unhealthy or not-synchronizing replica.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
