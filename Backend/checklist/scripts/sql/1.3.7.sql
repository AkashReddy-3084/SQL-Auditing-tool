-- Checklist: 1.3.7 Application connection endpoint is a failover-aware AG Listener / FCI virtual network name
-- Scope: SERVER
-- Scoring: 3=Alias matches AG Listener or FCI virtual name; 2=Alias differs from physical server name but not found in SQL Server HA config (proxy evidence, requires DNS verification); 1=Alias matches physical server name; 0=No HA topology configured or alias explicitly static.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @TargetAlias NVARCHAR(128) = 'C1SVPMLSQLAPP01';
DECLARE @ListenerNames NVARCHAR(MAX) = NULL;
DECLARE @FCIVirtualName NVARCHAR(128);
DECLARE @PhysicalName NVARCHAR(128);
DECLARE @IsFCI BIT;

-- Gather HA metadata safely across platforms
IF OBJECT_ID('sys.availability_group_listeners') IS NOT NULL
BEGIN
    SELECT @ListenerNames = STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name)
    FROM sys.availability_group_listeners;
END

SET @FCIVirtualName = CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(128));
SET @PhysicalName = CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS NVARCHAR(128));
SET @IsFCI = CASE WHEN @FCIVirtualName <> @PhysicalName THEN 1 ELSE 0 END;

-- Determine score and finding
IF @ListenerNames IS NOT NULL OR @IsFCI = 1
BEGIN
    IF UPPER(@TargetAlias) = UPPER(@FCIVirtualName) OR EXISTS (SELECT 1 FROM sys.availability_group_listeners WHERE UPPER(name) = UPPER(@TargetAlias))
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Alias matches failover-aware endpoint: ' + @TargetAlias;
    END
    ELSE IF UPPER(@TargetAlias) = UPPER(@PhysicalName)
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Alias matches physical server name: ' + @PhysicalName + '. Requires manual repointing on failover.';
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Alias not found in SQL Server HA configuration. Does not match physical server name. Requires external DNS/client verification.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No AG Listener or FCI virtual name configured on this instance. Alias cannot be verified as failover-aware.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;