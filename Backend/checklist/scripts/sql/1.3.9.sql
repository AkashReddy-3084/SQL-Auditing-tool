/* Checklist 1.3.9 - Alias / DNS resolution and failover behavior.
   Read-only proxy check: does a stable client-facing endpoint (AG listener or FCI
   virtual network name) exist so applications reconnect without being repointed? */
SET NOCOUNT ON;

DECLARE @EngineEdition INT           = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsClustered   INT           = CONVERT(INT, ISNULL(SERVERPROPERTY('IsClustered'), 0));
DECLARE @IsHadrEnabled INT           = CONVERT(INT, ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0));
DECLARE @ServerName    NVARCHAR(256) = CONVERT(NVARCHAR(256), ISNULL(SERVERPROPERTY('ServerName'), @@SERVERNAME));

DECLARE @Result     NVARCHAR(20);
DECLARE @Score      INT;
DECLARE @Finding    NVARCHAR(4000);
DECLARE @Sql        NVARCHAR(MAX);
DECLARE @QueryError NVARCHAR(500) = NULL;

IF OBJECT_ID('tempdb..#AG') IS NOT NULL DROP TABLE #AG;
CREATE TABLE #AG
(
    AgName        SYSNAME NOT NULL,
    ListenerCount INT     NOT NULL
);

IF OBJECT_ID('tempdb..#Listener') IS NOT NULL DROP TABLE #Listener;
CREATE TABLE #Listener
(
    AgName      SYSNAME        NOT NULL,
    DnsName     NVARCHAR(128)  NULL,
    ListenPort  INT            NULL,
    IpCount     INT            NOT NULL,
    SubnetCount INT            NOT NULL
);

/* Azure SQL Database / MI / Synapse / Edge do not expose a WSFC AG topology. */
IF @EngineEdition NOT IN (5, 6, 8, 9, 11)
   AND OBJECT_ID('sys.availability_groups') IS NOT NULL
   AND OBJECT_ID('sys.availability_group_listeners') IS NOT NULL
   AND OBJECT_ID('sys.availability_group_listener_ip_addresses') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'
        INSERT INTO #AG (AgName, ListenerCount)
        SELECT ag.name,
               (SELECT COUNT(*)
                  FROM sys.availability_group_listeners AS l
                 WHERE l.group_id = ag.group_id)
          FROM sys.availability_groups AS ag;

        INSERT INTO #Listener (AgName, DnsName, ListenPort, IpCount, SubnetCount)
        SELECT ag.name,
               l.dns_name,
               l.port,
               (SELECT COUNT(*)
                  FROM sys.availability_group_listener_ip_addresses AS ip
                 WHERE ip.listener_id = l.listener_id),
               (SELECT COUNT(DISTINCT ip.network_subnet_ip)
                  FROM sys.availability_group_listener_ip_addresses AS ip
                 WHERE ip.listener_id = l.listener_id)
          FROM sys.availability_group_listeners AS l
          INNER JOIN sys.availability_groups AS ag
                  ON ag.group_id = l.group_id;';

        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @QueryError = LEFT(ERROR_MESSAGE(), 400);
    END CATCH
END

DECLARE @AgCount       INT = (SELECT COUNT(*) FROM #AG);
DECLARE @AgNoListener  INT = (SELECT COUNT(*) FROM #AG WHERE ListenerCount = 0);
DECLARE @ListenerTotal INT = (SELECT COUNT(*) FROM #Listener);
DECLARE @ListenerNoIp  INT = (SELECT COUNT(*) FROM #Listener WHERE IpCount = 0);
DECLARE @MultiSubnet   INT = (SELECT COUNT(*) FROM #Listener WHERE SubnetCount > 1);

DECLARE @ListenerList NVARCHAR(2000) = N'';
SELECT @ListenerList = @ListenerList
     + CASE WHEN @ListenerList = N'' THEN N'' ELSE N'; ' END
     + AgName + N' -> ' + ISNULL(DnsName, N'(no DNS name)')
     + N':' + ISNULL(CONVERT(NVARCHAR(12), ListenPort), N'?')
     + N' (ips=' + CONVERT(NVARCHAR(12), IpCount)
     + N', subnets=' + CONVERT(NVARCHAR(12), SubnetCount) + N')'
  FROM #Listener;

DECLARE @NoListenerList NVARCHAR(2000) = N'';
SELECT @NoListenerList = @NoListenerList
     + CASE WHEN @NoListenerList = N'' THEN N'' ELSE N', ' END
     + AgName
  FROM #AG
 WHERE ListenerCount = 0;

SET @ListenerList   = LEFT(ISNULL(@ListenerList, N''), 1200);
SET @NoListenerList = LEFT(ISNULL(@NoListenerList, N''), 800);

IF @EngineEdition IN (5, 6, 8, 9, 11)
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Azure SQL platform detected (EngineEdition ' + CONVERT(NVARCHAR(12), @EngineEdition)
                 + N'). The client-facing DNS endpoint and its failover behaviour are managed by the service, not by the database engine, so they cannot be verified from T-SQL. Confirm that applications connect through the auto-failover group listener endpoint (not the individual logical server / instance FQDN), that the DNS alias and its TTL are documented, and that a failover drill proved transparent reconnection.';
END
ELSE IF @QueryError IS NOT NULL
BEGIN
    SET @Score   = 1;
    SET @Finding = N'The Always On listener catalog could not be read on ' + @ServerName
                 + N' (IsHadrEnabled=' + CONVERT(NVARCHAR(12), @IsHadrEnabled)
                 + N', IsClustered=' + CONVERT(NVARCHAR(12), @IsClustered)
                 + N'), typically because the Windows cluster is unreachable or the login lacks VIEW SERVER STATE, so the alias/failover control is unverified. Error: '
                 + @QueryError + N'. Re-run with sufficient permissions and confirm the listener / alias configuration and the documented failover behaviour manually.';
END
ELSE IF @AgCount > 0 AND (@AgNoListener > 0 OR @ListenerNoIp > 0)
BEGIN
    SET @Score   = 1;
    SET @Finding = N'On ' + @ServerName + N', ' + CONVERT(NVARCHAR(12), @AgCount)
                 + N' Availability Group(s) are configured but the client alias layer is incomplete: '
                 + CONVERT(NVARCHAR(12), @AgNoListener) + N' AG(s) have no listener'
                 + CASE WHEN @NoListenerList = N'' THEN N'' ELSE N' (' + @NoListenerList + N')' END
                 + N' and ' + CONVERT(NVARCHAR(12), @ListenerNoIp)
                 + N' listener(s) have no IP address configured. Listeners found: '
                 + CASE WHEN @ListenerList = N'' THEN N'none' ELSE @ListenerList END
                 + N'. Applications must therefore connect to individual replica/node names, so a failover requires a manual connection-string repoint.';
END
ELSE IF @AgCount > 0 AND @MultiSubnet > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'On ' + @ServerName + N', all ' + CONVERT(NVARCHAR(12), @AgCount)
                 + N' Availability Group(s) publish a listener, but ' + CONVERT(NVARCHAR(12), @MultiSubnet)
                 + N' of ' + CONVERT(NVARCHAR(12), @ListenerTotal)
                 + N' listener(s) span more than one subnet: ' + @ListenerList
                 + N'. Transparent reconnection in a multi-subnet topology additionally depends on RegisterAllProvidersIP, the cluster HostRecordTTL and MultiSubnetFailover=True in the client connection strings, none of which are visible from the engine. Confirm those settings and the documented/tested failover behaviour.';
END
ELSE IF @AgCount > 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'On ' + @ServerName + N', every one of the ' + CONVERT(NVARCHAR(12), @AgCount)
                 + N' Availability Group(s) publishes a single-subnet listener with at least one IP address, giving clients a stable DNS alias that survives failover: '
                 + @ListenerList + N'. No manual repoint is required when the primary replica moves.';
END
ELSE IF @IsClustered = 1
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Instance ' + @ServerName
                 + N' is a Failover Cluster Instance (SERVERPROPERTY IsClustered = 1) with no Availability Groups. Clients connect through the clustered virtual network name, which follows the instance to the surviving node, so failover is transparent and no connection-string repoint is needed.';
END
ELSE
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Instance ' + @ServerName
                 + N' is standalone: no Availability Groups (IsHadrEnabled=' + CONVERT(NVARCHAR(12), @IsHadrEnabled)
                 + N') and not clustered (IsClustered=' + CONVERT(NVARCHAR(12), @IsClustered)
                 + N'), so no engine-managed alias endpoint exists and there is no failover partner to repoint to. Any DNS CNAME or SQL client alias used to reach this instance lives outside SQL Server; verify from documentation that the alias, its resolution and the repoint procedure are recorded and have been validated.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result     AS Result,
       @Score      AS Score,
       @ServerName AS DatabaseQueried,
       @Finding    AS Finding;

IF OBJECT_ID('tempdb..#Listener') IS NOT NULL DROP TABLE #Listener;
IF OBJECT_ID('tempdb..#AG') IS NOT NULL DROP TABLE #AG;