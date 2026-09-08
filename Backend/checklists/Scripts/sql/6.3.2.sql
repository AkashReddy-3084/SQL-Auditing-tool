SET NOCOUNT ON;

DECLARE @EngineEdition     INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried   NVARCHAR(128)  = DB_NAME();
DECLARE @Result            NVARCHAR(20);
DECLARE @Score             INT            = 0;
DECLARE @Finding           NVARCHAR(4000) = N'';

IF @EngineEdition = 8
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Azure SQL Managed Instance detected (EngineEdition = 8). Managed Instance is always deployed into a delegated VNet subnet, so VNet integration / network isolation is enforced by the platform. Residual ARM-level confirmation recommended: subnet NSG and route table rules, and whether the public endpoint (port 3342) is disabled.';
END
ELSE IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: the Private Endpoint / publicNetworkAccess flag is ARM-only,
    -- so the public firewall-rule surface is used as the observable proxy.
    DECLARE @TotalRules INT = -1, @AllowAzure INT = 0, @AllOpen INT = 0, @WideRules INT = 0;
    DECLARE @RuleScope  NVARCHAR(30) = N'server-level';
    DECLARE @sql        NVARCHAR(MAX);

    BEGIN TRY
        IF DB_NAME() = N'master'
            SET @sql = N'SELECT @t = COUNT(*),
                                @a = SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''0.0.0.0'' THEN 1 ELSE 0 END),
                                @o = SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''255.255.255.255'' THEN 1 ELSE 0 END),
                                @w = SUM(CASE WHEN start_ip_address <> end_ip_address THEN 1 ELSE 0 END)
                         FROM sys.firewall_rules;';
        ELSE
        BEGIN
            SET @RuleScope = N'database-level';
            SET @sql = N'SELECT @t = COUNT(*),
                                @a = SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''0.0.0.0'' THEN 1 ELSE 0 END),
                                @o = SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''255.255.255.255'' THEN 1 ELSE 0 END),
                                @w = SUM(CASE WHEN start_ip_address <> end_ip_address THEN 1 ELSE 0 END)
                         FROM sys.database_firewall_rules;';
        END

        EXEC sp_executesql @sql,
             N'@t INT OUTPUT, @a INT OUTPUT, @o INT OUTPUT, @w INT OUTPUT',
             @t = @TotalRules OUTPUT, @a = @AllowAzure OUTPUT, @o = @AllOpen OUTPUT, @w = @WideRules OUTPUT;
    END TRY
    BEGIN CATCH
        SET @TotalRules = -1;
    END CATCH

    SET @AllowAzure = ISNULL(@AllowAzure, 0);
    SET @AllOpen    = ISNULL(@AllOpen, 0);
    SET @WideRules  = ISNULL(@WideRules, 0);

    IF @TotalRules = -1
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Azure SQL Database detected (EngineEdition = 5) but the firewall rule metadata could not be read from database [' + @DatabaseQueried + N']. Grant VIEW DATABASE STATE / connect to [master] and re-run, or confirm Private Endpoint and publicNetworkAccess = Disabled in the Azure portal. Manual review required.';
    END
    ELSE IF @AllOpen > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Azure SQL Database detected (EngineEdition = 5). ' + CAST(@AllOpen AS NVARCHAR(10)) + N' fully open ' + @RuleScope + N' firewall rule(s) (0.0.0.0 - 255.255.255.255) found out of ' + CAST(@TotalRules AS NVARCHAR(10)) + N' total rule(s). The public endpoint is reachable from the entire internet, which defeats any Private Endpoint / VNet isolation that may also be configured.';
    END
    ELSE IF @TotalRules = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Azure SQL Database detected (EngineEdition = 5). No ' + @RuleScope + N' firewall rules are defined, so no traffic can reach the logical server over the public endpoint; access is consistent with Private Endpoint / VNet-only connectivity. Residual ARM-level confirmation recommended: publicNetworkAccess = Disabled and an approved private endpoint connection exist.';
    END
    ELSE IF @AllowAzure > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Azure SQL Database detected (EngineEdition = 5). The "Allow Azure services and resources to access this server" rule (0.0.0.0 - 0.0.0.0) is present, alongside ' + CAST(@TotalRules AS NVARCHAR(10)) + N' total ' + @RuleScope + N' firewall rule(s) (' + CAST(@WideRules AS NVARCHAR(10)) + N' spanning an IP range). Public-endpoint access is still in use, so network isolation is only partial even if a private endpoint exists.';
    END
    ELSE
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Azure SQL Database detected (EngineEdition = 5). ' + CAST(@TotalRules AS NVARCHAR(10)) + N' ' + @RuleScope + N' firewall rule(s) restrict the public endpoint to specific IP addresses (' + CAST(@WideRules AS NVARCHAR(10)) + N' spanning an IP range). Traffic still traverses the public endpoint rather than a Private Endpoint / VNet path, so isolation is partial.';
    END
END
ELSE
BEGIN
    -- SQL Server (on-premises / IaaS): assess the exposed network surface.
    DECLARE @TcpEnabled    INT = NULL;
    DECLARE @ListenAll     INT = NULL;
    DECLARE @RegistryOk    BIT = 0;
    DECLARE @RemoteAccess  INT = NULL;
    DECLARE @PublicClients INT = -1;
    DECLARE @TotalClients  INT = 0;

    BEGIN TRY
        SELECT @TcpEnabled = MAX(CASE WHEN value_name = N'Enabled'        THEN CAST(value_data AS INT) END),
               @ListenAll  = MAX(CASE WHEN value_name = N'ListenOnAllIPs' THEN CAST(value_data AS INT) END)
        FROM sys.dm_server_registry
        WHERE registry_key LIKE N'%SuperSocketNetLib\Tcp';

        SET @RegistryOk = 1;
    END TRY
    BEGIN CATCH
        SET @RegistryOk = 0;
    END CATCH

    BEGIN TRY
        SELECT @RemoteAccess = CAST(value_in_use AS INT)
        FROM sys.configurations
        WHERE name = N'remote access';
    END TRY
    BEGIN CATCH
        SET @RemoteAccess = NULL;
    END CATCH

    BEGIN TRY
        SELECT @TotalClients  = COUNT(DISTINCT client_net_address),
               @PublicClients = COUNT(DISTINCT CASE
                                        WHEN client_net_address IS NOT NULL
                                         AND client_net_address <> N'<local machine>'
                                         AND client_net_address NOT LIKE N'127.%'
                                         AND client_net_address NOT LIKE N'10.%'
                                         AND client_net_address NOT LIKE N'192.168.%'
                                         AND client_net_address NOT LIKE N'169.254.%'
                                         AND client_net_address NOT LIKE N'172.1[6-9].%'
                                         AND client_net_address NOT LIKE N'172.2[0-9].%'
                                         AND client_net_address NOT LIKE N'172.3[0-1].%'
                                         AND client_net_address <> N'::1'
                                         AND client_net_address NOT LIKE N'fe80%'
                                         AND client_net_address NOT LIKE N'fc%'
                                         AND client_net_address NOT LIKE N'fd%'
                                        THEN client_net_address END)
        FROM sys.dm_exec_connections;
    END TRY
    BEGIN CATCH
        SET @PublicClients = -1;
    END CATCH

    DECLARE @Context NVARCHAR(1000) =
        N' Observed: TCP/IP protocol Enabled = ' + ISNULL(CAST(@TcpEnabled AS NVARCHAR(10)), N'unknown')
        + N', ListenOnAllIPs = ' + ISNULL(CAST(@ListenAll AS NVARCHAR(10)), N'unknown')
        + N', sp_configure "remote access" = ' + ISNULL(CAST(@RemoteAccess AS NVARCHAR(10)), N'unknown')
        + N', distinct client addresses in sys.dm_exec_connections = ' + CAST(@TotalClients AS NVARCHAR(10))
        + N', of which public (non-RFC1918, non-loopback) = ' + CASE WHEN @PublicClients < 0 THEN N'unreadable' ELSE CAST(@PublicClients AS NVARCHAR(10)) END + N'.';

    IF @RegistryOk = 0 OR @PublicClients = -1
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'SQL Server instance detected (EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'), but the network configuration could not be fully read; VIEW SERVER STATE is required for sys.dm_server_registry and sys.dm_exec_connections.' + @Context + N' Manual review required: verify firewall rules, subnet/NSG placement, and the SQL Server Configuration Manager protocol and IP settings.';
    END
    ELSE IF @TcpEnabled = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'SQL Server instance detected (EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). The TCP/IP protocol is disabled, so the instance accepts no remote network connections and is isolated to local protocols (Shared Memory / Named Pipes).' + @Context;
    END
    ELSE IF @PublicClients > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'SQL Server instance detected (EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). ' + CAST(@PublicClients AS NVARCHAR(10)) + N' distinct public (non-RFC1918, non-loopback) client address(es) are currently connected over TCP/IP, indicating the instance is reachable from outside a private / VNet-isolated network.' + @Context;
    END
    ELSE IF @ListenAll = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'SQL Server instance detected (EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). TCP/IP is enabled but ListenOnAllIPs is disabled (the instance is bound to specific IP addresses) and all current client connections originate from private or local addresses, which is consistent with network isolation.' + @Context;
    END
    ELSE
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'SQL Server instance detected (EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). TCP/IP is enabled and the instance listens on all IP addresses (ListenOnAllIPs = 1); all currently observed client addresses are private or local, so exposure is limited by the surrounding network rather than by the instance configuration.' + @Context + N' Confirm the host firewall / NSG restricts port access to the intended subnets.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;