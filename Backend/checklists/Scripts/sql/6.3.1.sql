-- Checklist: Firewall / network rules restrict access to known sources
-- Scope: SERVER
-- Scoring: 3 = firewall rules are defined and none opens the whole 0.0.0.0-255.255.255.255 range; 2 = no rule opens every address, or the instance shows a restricted set of client sources on its listening endpoints; 1 = an all-addresses rule exists, or more than 25 distinct client addresses were observed; 0 = no firewall, endpoint or connection evidence could be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No firewall, endpoint or connection evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Rules INT = -1;
DECLARE @OpenRules INT = 0;
DECLARE @AzureServiceRules INT = 0;
DECLARE @Endpoints INT = -1;
DECLARE @Stopped INT = 0;
DECLARE @Clients INT = 0;
DECLARE @Port NVARCHAR(40) = 'not readable';
DECLARE @Probe NVARCHAR(900);

IF @Engine = 5
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @r = COUNT(*),
       @o = ISNULL(SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''255.255.255.255'' THEN 1 ELSE 0 END), 0),
       @a = ISNULL(SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''0.0.0.0'' THEN 1 ELSE 0 END), 0)
FROM sys.firewall_rules;';
        EXEC sys.sp_executesql @Probe, N'@r INT OUTPUT, @o INT OUTPUT, @a INT OUTPUT',
             @r = @Rules OUTPUT, @o = @OpenRules OUTPUT, @a = @AzureServiceRules OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Rules = -1;
    END CATCH

    IF @Rules = -1
    BEGIN
        BEGIN TRY
            SET @Probe = N'SELECT @r = COUNT(*),
       @o = ISNULL(SUM(CASE WHEN start_ip_address = ''0.0.0.0'' AND end_ip_address = ''255.255.255.255'' THEN 1 ELSE 0 END), 0)
FROM sys.database_firewall_rules;';
            EXEC sys.sp_executesql @Probe, N'@r INT OUTPUT, @o INT OUTPUT',
                 @r = @Rules OUTPUT, @o = @OpenRules OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Rules = -1;
        END CATCH
    END
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Endpoints = COUNT(*),
               @Stopped = ISNULL(SUM(CASE WHEN state_desc <> 'STARTED' THEN 1 ELSE 0 END), 0)
        FROM sys.tcp_endpoints
        WHERE type_desc = 'TSQL';
    END TRY
    BEGIN CATCH
        SET @Endpoints = -1;
    END CATCH

    BEGIN TRY
        SELECT @Clients = COUNT(DISTINCT client_net_address)
        FROM sys.dm_exec_connections
        WHERE client_net_address IS NOT NULL
          AND client_net_address NOT LIKE '%local machine%';
    END TRY
    BEGIN CATCH
        SET @Clients = 0;
    END CATCH

    BEGIN TRY
        SET @Probe = N'SELECT @p = ISNULL(MAX(CONVERT(NVARCHAR(40), value_data)), N''not readable'')
FROM sys.dm_server_registry
WHERE value_name = ''TcpPort'' AND CONVERT(NVARCHAR(40), value_data) <> N'''';';
        EXEC sys.sp_executesql @Probe, N'@p NVARCHAR(40) OUTPUT', @p = @Port OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Port = 'not readable';
    END CATCH
END

SET @Score = CASE
    WHEN @Engine = 5 AND @Rules = -1 THEN 0
    WHEN @Engine = 5 AND @OpenRules > 0 THEN 1
    WHEN @Engine = 5 AND @Rules = 0 THEN 2
    WHEN @Engine = 5 THEN 3
    WHEN @Endpoints = -1 AND @Clients = 0 THEN 0
    WHEN @Clients > 25 THEN 1
    ELSE 2 END;

SET @Finding = CASE
    WHEN @Engine = 5 AND @Rules = -1 THEN 'Azure SQL Database firewall rules could not be read from this connection'
    WHEN @Engine = 5 THEN CONCAT('Azure SQL Database firewall rules = ', @Rules,
                                 ', rules opening 0.0.0.0-255.255.255.255 = ', @OpenRules,
                                 ', Azure-services rules (0.0.0.0-0.0.0.0) = ', @AzureServiceRules)
    ELSE CONCAT('TSQL endpoints = ', CASE WHEN @Endpoints = -1 THEN 'not readable' ELSE CONVERT(NVARCHAR(10), @Endpoints) END,
                ', endpoints not started = ', @Stopped,
                ', distinct remote client addresses observed = ', @Clients,
                ', listening TCP port = ', @Port,
                '; host and network firewall rules are not exposed to T-SQL')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
