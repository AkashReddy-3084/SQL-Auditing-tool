-- Checklist: Private endpoints / VNet integration used (Azure SQL) or network isolation (SQL Server)
-- Scope: SERVER
-- Scoring: 3=Fully isolated, 2=Partial isolation, 1=No rules/No active connections (proxy evidence), 0=Public access detected
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition IN (5, 8)
BEGIN
    -- Azure SQL Database / Azure SQL Managed Instance
    DECLARE @VNetRules INT = 0;
    DECLARE @PublicRules INT = 0;
    
    SELECT @VNetRules = COUNT(*) FROM sys.firewall_rules WHERE is_virtual_network_rule = 1;
    SELECT @PublicRules = COUNT(*) FROM sys.firewall_rules WHERE is_virtual_network_rule = 0;
    
    IF @VNetRules > 0 AND @PublicRules = 0
        SET @Score = 3;
    ELSE IF @VNetRules > 0 AND @PublicRules > 0
        SET @Score = 2;
    ELSE IF @VNetRules = 0 AND @PublicRules > 0
        SET @Score = 0;
    ELSE
        SET @Score = 1;
        
    SET @Finding = 'Azure SQL: VNet rules=' + CAST(@VNetRules AS NVARCHAR(10)) + ', Public firewall rules=' + CAST(@PublicRules AS NVARCHAR(10));
END
ELSE
BEGIN
    -- SQL Server (On-prem / Azure VM)
    DECLARE @TotalConns INT = 0;
    DECLARE @PrivateConns INT = 0;
    
    SELECT 
        @TotalConns = COUNT(*),
        @PrivateConns = COUNT(CASE 
            WHEN client_net_address LIKE '10.%' 
              OR client_net_address LIKE '172.1[6-9].%' 
              OR client_net_address LIKE '172.2[0-9].%' 
              OR client_net_address LIKE '172.3[0-1].%' 
              OR client_net_address LIKE '192.168.%' 
              OR client_net_address LIKE '127.%' 
              OR client_net_address IS NULL 
            THEN 1 
        END)
    FROM sys.dm_exec_connections;
    
    IF @TotalConns = 0
        SET @Score = 1;
    ELSE IF @PrivateConns = @TotalConns
        SET @Score = 3;
    ELSE IF @PrivateConns > 0
        SET @Score = 2;
    ELSE
        SET @Score = 0;
        
    SET @Finding = 'SQL Server: Total active connections=' + CAST(@TotalConns AS NVARCHAR(10)) + ', Private IP connections=' + CAST(@PrivateConns AS NVARCHAR(10)) + ', Public IP connections=' + CAST(@TotalConns - @PrivateConns AS NVARCHAR(10));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;