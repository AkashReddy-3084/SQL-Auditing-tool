/* Checklist 1.3.5 - Connection strings use listener / failover-group endpoints (not a single node)
   Scope: SERVER. Strictly read-only.
   local_net_address is the server-side IP the client dialled, so it distinguishes a listener VIP from a node IP. */
SET NOCOUNT ON;

DECLARE @Result          nvarchar(20)   = N'Fail';
DECLARE @Score           int            = 0;
DECLARE @Finding         nvarchar(max)  = N'';
DECLARE @DatabaseQueried nvarchar(256)  = DB_NAME();
DECLARE @EngineEdition   int            = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsHadrEnabled   int            = ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0);
DECLARE @IsClustered     int            = ISNULL(CONVERT(int, SERVERPROPERTY('IsClustered')), 0);
DECLARE @HasServerState  int            = ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0);
DECLARE @AgCount         int            = 0;
DECLARE @ListenerIpCount int            = 0;
DECLARE @TotalConn       int            = 0;
DECLARE @ViaListener     int            = 0;
DECLARE @ListenerList    nvarchar(2000) = N'';
DECLARE @BypassList      nvarchar(2000) = N'';

CREATE TABLE #Listener
(
    dns_name    nvarchar(128) NULL,
    listen_port int           NULL,
    ip_address  nvarchar(48)  NULL
);

CREATE TABLE #Conn
(
    session_id         int           NOT NULL,
    local_net_address  varchar(48)   NULL,
    client_net_address varchar(48)   NULL,
    program_name       nvarchar(128) NULL,
    via_listener       bit           NOT NULL
);

IF @EngineEdition <> 5 AND @HasServerState = 1
BEGIN
    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        EXEC sp_executesql
             N'SELECT @c = COUNT(*) FROM sys.availability_groups;',
             N'@c int OUTPUT',
             @c = @AgCount OUTPUT;
    END

    IF OBJECT_ID('sys.availability_group_listeners') IS NOT NULL
       AND OBJECT_ID('sys.availability_group_listener_ip_addresses') IS NOT NULL
    BEGIN
        INSERT INTO #Listener (dns_name, listen_port, ip_address)
        EXEC sp_executesql
             N'SELECT l.dns_name,
                      l.port,
                      ip.ip_address
               FROM sys.availability_group_listeners AS l
               LEFT JOIN sys.availability_group_listener_ip_addresses AS ip
                      ON ip.listener_id = l.listener_id;';
    END

    SELECT @ListenerIpCount = COUNT(*)
    FROM #Listener
    WHERE ip_address IS NOT NULL;

    INSERT INTO #Conn (session_id, local_net_address, client_net_address, program_name, via_listener)
    SELECT c.session_id,
           c.local_net_address,
           c.client_net_address,
           s.program_name,
           CASE WHEN EXISTS (SELECT 1
                             FROM #Listener AS L
                             WHERE L.ip_address IS NOT NULL
                               AND L.ip_address = c.local_net_address)
                THEN CONVERT(bit, 1)
                ELSE CONVERT(bit, 0)
           END
    FROM sys.dm_exec_connections AS c
    INNER JOIN sys.dm_exec_sessions AS s
            ON s.session_id = c.session_id
    WHERE s.is_user_process = 1
      AND c.session_id <> @@SPID
      AND c.net_transport = 'TCP'
      AND c.local_net_address IS NOT NULL
      AND c.client_net_address IS NOT NULL
      AND c.client_net_address <> '<local machine>';

    SELECT @TotalConn   = COUNT(*),
           @ViaListener = SUM(CASE WHEN via_listener = 1 THEN 1 ELSE 0 END)
    FROM #Conn;

    SET @ViaListener = ISNULL(@ViaListener, 0);

    SELECT @ListenerList = ISNULL(STUFF((SELECT DISTINCT N', ' + L.dns_name + N':' + CONVERT(nvarchar(10), ISNULL(L.listen_port, 0))
                                         FROM #Listener AS L
                                         WHERE L.dns_name IS NOT NULL
                                         FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N''), N'');

    SELECT @BypassList = ISNULL(STUFF((SELECT DISTINCT N', ' + C.local_net_address
                                       FROM #Conn AS C
                                       WHERE C.via_listener = 0
                                       FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N''), N'');
END

IF @EngineEdition = 5
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database: the engine does not expose which endpoint (logical server vs failover-group listener) the client connection string targeted, so listener usage could not be confirmed. Verify from application configuration that connection strings use the failover-group endpoint rather than the individual logical server name.';
END
ELSE IF @HasServerState = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'VIEW SERVER STATE is not held by the audit login, so sys.dm_exec_connections could not be sampled and the endpoint used by client connection strings could not be determined. Re-run with VIEW SERVER STATE granted.';
END
ELSE IF @IsHadrEnabled = 1 AND @ListenerIpCount > 0 AND @TotalConn = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Availability group listener(s) configured (' + @ListenerList + N') but there were no active remote TCP user connections at sample time, so no live connection string could be observed. Re-run during application activity to confirm client usage.';
END
ELSE IF @IsHadrEnabled = 1 AND @ListenerIpCount > 0 AND @ViaListener = @TotalConn
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CONVERT(nvarchar(10), @TotalConn) + N' sampled remote user connection(s) arrived on an availability group listener IP. Listener(s): ' + @ListenerList + N'.';
END
ELSE IF @IsHadrEnabled = 1 AND @ListenerIpCount > 0 AND @ViaListener > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Mixed endpoints: ' + CONVERT(nvarchar(10), @ViaListener) + N' of ' + CONVERT(nvarchar(10), @TotalConn)
                 + N' sampled remote user connection(s) used a listener IP; the remaining ' + CONVERT(nvarchar(10), @TotalConn - @ViaListener)
                 + N' connected directly to node address(es) ' + @BypassList + N'. Listener(s): ' + @ListenerList + N'.';
END
ELSE IF @IsHadrEnabled = 1 AND @ListenerIpCount > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of the ' + CONVERT(nvarchar(10), @TotalConn) + N' sampled remote user connection(s) used a listener IP; all connected directly to node address(es) ' + @BypassList
                 + N'. Configured listener(s) not in use: ' + @ListenerList + N'.';
END
ELSE IF @IsHadrEnabled = 1 AND @AgCount > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Always On is enabled with ' + CONVERT(nvarchar(10), @AgCount) + N' availability group(s) but no listener IP is configured, so every connection string must target an individual node and will not follow a failover.';
END
ELSE IF @IsClustered = 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'Failover cluster instance: the instance is reachable only through its clustered virtual network name, so connection strings cannot be pinned to a single node. ' + CONVERT(nvarchar(10), @TotalConn) + N' remote user connection(s) sampled.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Standalone instance: Always On is not enabled, no availability group listener exists and the instance is not clustered, so no listener or failover-group endpoint is available for connection strings; all clients necessarily target a single node.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #Conn;
DROP TABLE #Listener;