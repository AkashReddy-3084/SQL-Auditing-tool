SET NOCOUNT ON;

DECLARE @AppAlias              sysname        = N'C1SVPMLSQLAPP01';
DECLARE @EngineEdition         int            = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsClustered           int            = CONVERT(int, ISNULL(SERVERPROPERTY('IsClustered'), 0));
DECLARE @IsHadrEnabled         int            = CONVERT(int, ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0));
DECLARE @VirtualName           nvarchar(128)  = CONVERT(nvarchar(128), SERVERPROPERTY('MachineName'));
DECLARE @PhysicalName          nvarchar(128)  = CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS'));
DECLARE @InstanceName          nvarchar(256)  = CONVERT(nvarchar(256), @@SERVERNAME);
DECLARE @ListenerCount         int            = 0;
DECLARE @AGCount               int            = 0;
DECLARE @ListenerList          nvarchar(2000) = N'';
DECLARE @AliasMatchesEndpoint  int            = 0;
DECLARE @MatchedEndpoint       nvarchar(256)  = N'';
DECLARE @Result                nvarchar(20);
DECLARE @Score                 int;
DECLARE @Finding               nvarchar(4000);

IF OBJECT_ID('tempdb..#Listeners') IS NOT NULL DROP TABLE #Listeners;
CREATE TABLE #Listeners
(
    dns_name  nvarchar(128) NULL,
    port      int           NULL,
    ag_name   nvarchar(128) NULL
);

IF OBJECT_ID('sys.availability_group_listeners') IS NOT NULL
BEGIN
    INSERT INTO #Listeners (dns_name, port, ag_name)
    EXEC sp_executesql N'
        SELECT agl.dns_name, agl.port, ag.name
        FROM sys.availability_group_listeners AS agl
        LEFT JOIN sys.availability_groups AS ag
               ON ag.group_id = agl.group_id;';
END

IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    DECLARE @AGCountSql nvarchar(200) = N'SELECT @cnt = COUNT(*) FROM sys.availability_groups;';
    EXEC sp_executesql @AGCountSql, N'@cnt int OUTPUT', @cnt = @AGCount OUTPUT;
END

SELECT @ListenerCount = COUNT(*) FROM #Listeners;

SELECT @ListenerList = @ListenerList
     + CASE WHEN @ListenerList = N'' THEN N'' ELSE N', ' END
     + ISNULL(dns_name, N'(unnamed)')
     + N':' + CONVERT(nvarchar(10), ISNULL(port, 0))
     + N' [AG=' + ISNULL(ag_name, N'unknown') + N']'
FROM #Listeners;

IF EXISTS
(
    SELECT 1
    FROM #Listeners
    WHERE dns_name IS NOT NULL
      AND UPPER(LEFT(dns_name, CHARINDEX('.', dns_name + '.') - 1)) = UPPER(@AppAlias)
)
BEGIN
    SET @AliasMatchesEndpoint = 1;
    SET @MatchedEndpoint = N'AG Listener ' + @AppAlias;
END

IF @AliasMatchesEndpoint = 0
   AND @IsClustered = 1
   AND @VirtualName IS NOT NULL
   AND UPPER(LEFT(@VirtualName, CHARINDEX('.', @VirtualName + '.') - 1)) = UPPER(@AppAlias)
BEGIN
    SET @AliasMatchesEndpoint = 1;
    SET @MatchedEndpoint = N'FCI virtual network name ' + @VirtualName;
END

IF @EngineEdition IN (5, 6, 8, 9, 11)
BEGIN
    SET @Score = 3;
    SET @Finding = N'Azure SQL platform detected (EngineEdition ' + CONVERT(nvarchar(10), @EngineEdition)
                 + N'). Client connections use the platform logical-server / managed-instance gateway endpoint, which is inherently failover-aware and is not repointed manually. Alias under review: ' + @AppAlias + N'.';
END
ELSE IF @AliasMatchesEndpoint = 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'Application alias ' + @AppAlias + N' matches a failover-aware endpoint on this instance: ' + @MatchedEndpoint
                 + N'. IsClustered=' + CONVERT(nvarchar(10), @IsClustered)
                 + N', IsHadrEnabled=' + CONVERT(nvarchar(10), @IsHadrEnabled)
                 + N', AG listeners configured=' + CONVERT(nvarchar(10), @ListenerCount)
                 + CASE WHEN @ListenerCount > 0 THEN N' (' + @ListenerList + N')' ELSE N'' END
                 + N'. Virtual/machine name=' + ISNULL(@VirtualName, N'(unknown)')
                 + N', physical node=' + ISNULL(@PhysicalName, N'(unknown)') + N'.';
END
ELSE IF @ListenerCount > 0 OR @IsClustered = 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'A failover-aware endpoint exists but it does not carry the application alias name ' + @AppAlias
                 + N'. AG listeners configured=' + CONVERT(nvarchar(10), @ListenerCount)
                 + CASE WHEN @ListenerCount > 0 THEN N' (' + @ListenerList + N')' ELSE N'' END
                 + N'; IsClustered=' + CONVERT(nvarchar(10), @IsClustered)
                 + N', virtual/machine name=' + ISNULL(@VirtualName, N'(unknown)')
                 + N', physical node=' + ISNULL(@PhysicalName, N'(unknown)')
                 + N', instance=' + ISNULL(@InstanceName, N'(unknown)')
                 + N'. The alias is therefore a DNS CNAME or SQL client alias layered over the endpoint and must be confirmed at DNS/registry level to prove it does not require manual repointing on failover.';
END
ELSE IF @IsHadrEnabled = 1 OR @AGCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'HADR is enabled (IsHadrEnabled=' + CONVERT(nvarchar(10), @IsHadrEnabled)
                 + N', availability groups=' + CONVERT(nvarchar(10), @AGCount)
                 + N') but no AG Listener is configured on this instance, so applications must connect to a node/instance name ('
                 + ISNULL(@InstanceName, N'(unknown)') + N'). Alias ' + @AppAlias
                 + N' cannot be resolving to a failover-aware listener and would need manual repointing after a role change.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'No failover-aware connection endpoint exists: IsClustered=0, IsHadrEnabled=' + CONVERT(nvarchar(10), @IsHadrEnabled)
                 + N', AG listeners configured=0, availability groups=' + CONVERT(nvarchar(10), @AGCount)
                 + N'. Instance=' + ISNULL(@InstanceName, N'(unknown)')
                 + N', machine name=' + ISNULL(@VirtualName, N'(unknown)')
                 + N', physical node=' + ISNULL(@PhysicalName, N'(unknown)')
                 + N'. Alias ' + @AppAlias + N' can only resolve to this static standalone instance name and must be manually repointed on failover.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result   AS Result,
    @Score    AS Score,
    N'master' AS DatabaseQueried,
    @Finding  AS Finding;

IF OBJECT_ID('tempdb..#Listeners') IS NOT NULL DROP TABLE #Listeners;