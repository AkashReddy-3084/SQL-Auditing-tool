/*
    Checklist item : 6.3.4 - No broad "allow Azure services" / 0.0.0.0 firewall rules
    Scope          : SERVER (connect to master on Azure SQL Database for full coverage)
    Read-only      : SELECT-only against catalog views; temp table used for staging.
*/
SET NOCOUNT ON;

DECLARE @EngineEdition      INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried    NVARCHAR(128)  = CAST(DB_NAME() AS NVARCHAR(128));
DECLARE @Result             NVARCHAR(30);
DECLARE @Score              INT;
DECLARE @Finding            NVARCHAR(4000);
DECLARE @CollectionError    NVARCHAR(2000) = NULL;
DECLARE @ServerRulesRead    BIT            = 0;
DECLARE @DatabaseRulesRead  BIT            = 0;
DECLARE @ServerViewExists   BIT            = CASE WHEN OBJECT_ID('sys.firewall_rules') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @DatabaseViewExists BIT            = CASE WHEN OBJECT_ID('sys.database_firewall_rules') IS NOT NULL THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#FirewallRules') IS NOT NULL
    DROP TABLE #FirewallRules;

CREATE TABLE #FirewallRules
(
    RuleScope NVARCHAR(20)  NOT NULL,
    RuleName  NVARCHAR(256) NULL,
    StartIp   NVARCHAR(45)  NULL,
    EndIp     NVARCHAR(45)  NULL
);

/* Server-level IP firewall rules - visible only in the master database of Azure SQL Database. */
IF @ServerViewExists = 1
BEGIN
    BEGIN TRY
        INSERT INTO #FirewallRules (RuleScope, RuleName, StartIp, EndIp)
        EXEC sp_executesql N'
            SELECT N''Server-level'',
                   CONVERT(NVARCHAR(256), name),
                   CONVERT(NVARCHAR(45), start_ip_address),
                   CONVERT(NVARCHAR(45), end_ip_address)
            FROM sys.firewall_rules;';

        SET @ServerRulesRead = 1;
    END TRY
    BEGIN CATCH
        SET @CollectionError = N'Server-level firewall rules could not be read: ' + ERROR_MESSAGE();
    END CATCH
END

/* Database-level IP firewall rules for the connected database. */
IF @DatabaseViewExists = 1
BEGIN
    BEGIN TRY
        INSERT INTO #FirewallRules (RuleScope, RuleName, StartIp, EndIp)
        EXEC sp_executesql N'
            SELECT N''Database-level'',
                   CONVERT(NVARCHAR(256), name),
                   CONVERT(NVARCHAR(45), start_ip_address),
                   CONVERT(NVARCHAR(45), end_ip_address)
            FROM sys.database_firewall_rules;';

        SET @DatabaseRulesRead = 1;
    END TRY
    BEGIN CATCH
        SET @CollectionError = ISNULL(@CollectionError + N' ', N'')
                             + N'Database-level firewall rules could not be read: ' + ERROR_MESSAGE();
    END CATCH
END

DECLARE @TotalRules      INT = 0;
DECLARE @AllowAzureCount INT = 0;
DECLARE @OpenToAllCount  INT = 0;
DECLARE @BroadCount      INT = 0;
DECLARE @Detail          NVARCHAR(MAX) = NULL;

SELECT @TotalRules      = COUNT(*),
       @AllowAzureCount = SUM(CASE WHEN StartIp = N'0.0.0.0' AND EndIp = N'0.0.0.0' THEN 1 ELSE 0 END),
       @OpenToAllCount  = SUM(CASE WHEN StartIp = N'0.0.0.0' AND EndIp = N'255.255.255.255' THEN 1 ELSE 0 END),
       @BroadCount      = SUM(CASE WHEN StartIp = N'0.0.0.0' OR  EndIp = N'255.255.255.255' THEN 1 ELSE 0 END)
FROM #FirewallRules;

SELECT @Detail = STUFF((SELECT N'; ' + fr.RuleScope
                             + N' ' + ISNULL(fr.RuleName, N'(unnamed)')
                             + N' [' + ISNULL(fr.StartIp, N'?') + N' - ' + ISNULL(fr.EndIp, N'?') + N']'
                        FROM #FirewallRules AS fr
                        WHERE fr.StartIp = N'0.0.0.0'
                           OR fr.EndIp   = N'255.255.255.255'
                        ORDER BY fr.RuleScope, fr.RuleName
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF OBJECT_ID('tempdb..#FirewallRules') IS NOT NULL
    DROP TABLE #FirewallRules;

IF @EngineEdition = 8
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Managed Instance (EngineEdition 8) does not expose IP firewall rules through T-SQL; connectivity is governed by VNet subnet delegation and network security group rules. Manual review required: confirm that no NSG rule or public endpoint configuration allows 0.0.0.0/0 or the broad "Allow Azure services" equivalent.';
END
ELSE IF @ServerViewExists = 0 AND @DatabaseViewExists = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Neither sys.firewall_rules nor sys.database_firewall_rules exists on this instance (EngineEdition '
                 + CAST(@EngineEdition AS NVARCHAR(10))
                 + N'), so Azure IP firewall rules are not a feature of this platform and no broad "allow Azure services" or 0.0.0.0 rule can be present. Network access is controlled outside the database engine.';
END
ELSE IF @ServerRulesRead = 0 AND @DatabaseRulesRead = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Firewall rule catalog views are present but could not be read with the current permissions, so broad rules could not be confirmed or ruled out. '
                 + ISNULL(@CollectionError, N'No rows were returned and no error was raised.')
                 + N' Re-run connected to master with a login that is a member of the loginmanager role or the server administrator.';
END
ELSE IF @BroadCount > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Found ' + CAST(@BroadCount AS NVARCHAR(10)) + N' broad firewall rule(s) out of '
                 + CAST(@TotalRules AS NVARCHAR(10)) + N' total: '
                 + CAST(@AllowAzureCount AS NVARCHAR(10)) + N' "Allow Azure services" rule(s) (0.0.0.0 - 0.0.0.0) and '
                 + CAST(@OpenToAllCount AS NVARCHAR(10)) + N' open-to-internet rule(s) (0.0.0.0 - 255.255.255.255). Offending rules: '
                 + LEFT(ISNULL(@Detail, N'(rule names unavailable)'), 3000) + N'.';
END
ELSE IF @ServerRulesRead = 0 AND @DatabaseRulesRead = 1
BEGIN
    SET @Score = 1;
    SET @Finding = N'No broad rule was found among the ' + CAST(@TotalRules AS NVARCHAR(10))
                 + N' database-level firewall rule(s) readable from database [' + @DatabaseQueried
                 + N'], but server-level rules in sys.firewall_rules were not visible from this connection, so an "Allow Azure services" or 0.0.0.0 rule may still exist at server scope. Re-run connected to master.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@TotalRules AS NVARCHAR(10))
                 + N' firewall rule(s) readable from this connection are scoped to specific IP ranges; no rule starts at 0.0.0.0 and none ends at 255.255.255.255, so neither the "Allow Azure services" rule nor an open-to-internet range is configured.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;