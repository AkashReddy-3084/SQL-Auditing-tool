-- Checklist: Application connection endpoint is a failover-aware AG Listener / FCI virtual network name
-- Scope: SERVER
-- Scoring: 0=Alias not found in AG/FCI config or linked servers; 1=Alias found in linked servers but not failover-aware; 2=Alias matches AG listener or FCI virtual name; 3=Alias matches AG listener with >=2 replicas
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TargetAlias NVARCHAR(256) = 'C1SVPMLSQLAPP01';
DECLARE @IsListener BIT = 0;
DECLARE @IsFCIVirtual BIT = 0;
DECLARE @ReplicaCount INT = 0;

-- Check AG Listener (On-Prem/MI only)
IF OBJECT_ID('master.sys.availability_group_listeners') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM master.sys.availability_group_listeners WHERE listener_name = @TargetAlias)
    BEGIN
        SET @IsListener = 1;
        -- Count replicas specifically for the AG associated with this listener
        SELECT @ReplicaCount = COUNT(*)
        FROM master.sys.availability_replicas ar
        INNER JOIN master.sys.availability_group_listeners agl ON ar.group_id = agl.group_id
        WHERE agl.listener_name = @TargetAlias;
    END
END

-- Check FCI Virtual Name
IF CAST(SERVERPROPERTY('IsClustered') AS BIT) = 1
BEGIN
    DECLARE @ServerName NVARCHAR(256) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));
    -- In FCI, ServerName returns the virtual network name
    IF @ServerName = @TargetAlias
        SET @IsFCIVirtual = 1;
END

-- Determine Score based on findings
IF @IsListener = 1
BEGIN
    IF @ReplicaCount >= 2
        SET @Score = 3;
    ELSE
        SET @Score = 2;
END
ELSE IF @IsFCIVirtual = 1
BEGIN
    SET @Score = 2;
END
ELSE
BEGIN
    -- Proxy evidence: check if alias is used in linked servers
    IF EXISTS (SELECT 1 FROM master.sys.servers WHERE server_name = @TargetAlias OR data_source = @TargetAlias)
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;