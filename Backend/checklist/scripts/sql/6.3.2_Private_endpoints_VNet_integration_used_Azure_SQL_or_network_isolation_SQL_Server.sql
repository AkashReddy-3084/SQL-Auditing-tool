-- Checklist: Private endpoints / VNet integration used (Azure SQL) or network isolation (SQL Server)
-- Scope: SERVER
-- Scoring: 0 = No evidence of network isolation or firewall rules. 1 = Partial evidence. 2 = Good evidence. Max capped at 2.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

-- Azure SQL DB (EngineEdition 5) or SQL MI (EngineEdition 8)
IF @EngineEdition IN (5, 8) AND OBJECT_ID('sys.firewall_rules') IS NOT NULL
BEGIN
    DECLARE @FirewallCount INT = 0;
    DECLARE @BroadAccess BIT = 0;
    
    SELECT @FirewallCount = COUNT(*) FROM sys.firewall_rules;
    SELECT @BroadAccess = ISNULL(MAX(CASE WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255' THEN 1 ELSE 0 END), 0) FROM sys.firewall_rules;
    
    IF @FirewallCount > 0 AND @BroadAccess = 0
        SET @Score = 2;
    ELSE IF @FirewallCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END
ELSE
BEGIN
    -- On-prem / SQL Server: Check endpoints for restrictions
    DECLARE @TotalEndpoints INT = 0;
    DECLARE @RestrictedEndpoints INT = 0;
    
    SELECT @TotalEndpoints = COUNT(*) FROM sys.endpoints WHERE type_desc IN ('TSQL', 'DATABASE_MIRRORING');
    SELECT @RestrictedEndpoints = COUNT(*) FROM sys.endpoints 
    WHERE type_desc IN ('TSQL', 'DATABASE_MIRRORING') 
    AND (is_disabled = 1 OR principal_id IS NOT NULL);
    
    IF @TotalEndpoints > 0
    BEGIN
        IF @RestrictedEndpoints = @TotalEndpoints
            SET @Score = 2;
        ELSE IF @RestrictedEndpoints > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;
    END
    ELSE
    BEGIN
        SET @Score = 0; -- No endpoints found = no evidence of isolation
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.