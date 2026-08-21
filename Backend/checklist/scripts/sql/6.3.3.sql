/*
    Checklist Item : 6.3.3 - Public network access disabled or tightly restricted (Azure SQL)
    Scope          : SERVER (execute against the master database of the Azure SQL logical server)
    Access         : Read-only. Catalog views only; results are staged in a session temp table.
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @DatabaseQueried NVARCHAR(128)  = CONVERT(NVARCHAR(128), DB_NAME());
DECLARE @Result          NVARCHAR(50)   = N'Fail';
DECLARE @Score           INT            = 0;
DECLARE @Finding         NVARCHAR(4000) = N'';

IF OBJECT_ID('tempdb..#FirewallRules') IS NOT NULL
    DROP TABLE #FirewallRules;

CREATE TABLE #FirewallRules
(
    RuleScope NVARCHAR(20)  NOT NULL,
    RuleName  NVARCHAR(256) NULL,
    StartIp   NVARCHAR(45)  NULL,
    EndIp     NVARCHAR(45)  NULL
);

/* EngineEdition 5 = Azure SQL Database, 6 = Azure Synapse Analytics, 11 = Azure Synapse serverless */
IF @EngineEdition IN (5, 6, 11)
BEGIN
    /* Dynamic SQL keeps the batch compilable on engines where these Azure-only catalog views do not exist. */
    IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
        EXEC sp_executesql N'
            INSERT INTO #FirewallRules (RuleScope, RuleName, StartIp, EndIp)
            SELECT N''Server'',
                   CONVERT(NVARCHAR(256), name),
                   CONVERT(NVARCHAR(45), start_ip_address),
                   CONVERT(NVARCHAR(45), end_ip_address)
            FROM sys.firewall_rules;';

    IF OBJECT_ID('sys.database_firewall_rules') IS NOT NULL
        EXEC sp_executesql N'
            INSERT INTO #FirewallRules (RuleScope, RuleName, StartIp, EndIp)
            SELECT N''Database'',
                   CONVERT(NVARCHAR(256), name),
                   CONVERT(NVARCHAR(45), start_ip_address),
                   CONVERT(NVARCHAR(45), end_ip_address)
            FROM sys.database_firewall_rules;';
END

DECLARE @TotalRules INT =
(
    SELECT COUNT(*) FROM #FirewallRules
);

DECLARE @OpenToWorld INT =
(
    SELECT COUNT(*)
    FROM #FirewallRules
    WHERE StartIp = N'0.0.0.0'
      AND EndIp   = N'255.255.255.255'
);

DECLARE @AzureServices INT =
(
    SELECT COUNT(*)
    FROM #FirewallRules
    WHERE StartIp = N'0.0.0.0'
      AND EndIp   = N'0.0.0.0'
);

DECLARE @WideRanges INT =
(
    SELECT COUNT(*)
    FROM #FirewallRules
    WHERE NOT (StartIp = N'0.0.0.0' AND EndIp = N'0.0.0.0')
      AND NOT (StartIp = N'0.0.0.0' AND EndIp = N'255.255.255.255')
      AND ISNULL(PARSENAME(StartIp, 4), N'') <> ISNULL(PARSENAME(EndIp, 4), N'')
);

DECLARE @NarrowRules INT = @TotalRules - @OpenToWorld - @AzureServices - @WideRanges;

DECLARE @RuleList NVARCHAR(2000);

SELECT @RuleList = STUFF
(
    (
        SELECT TOP (10)
               N'; ' + r.RuleScope + N':' + ISNULL(r.RuleName, N'(unnamed)')
             + N' ' + ISNULL(r.StartIp, N'?') + N'-' + ISNULL(r.EndIp, N'?')
        FROM #FirewallRules AS r
        ORDER BY r.RuleScope, r.RuleName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(2000)'), 1, 2, N''
);

DECLARE @RuleSummary NVARCHAR(3000) =
      N'Firewall rules visible from the data plane: total=' + CONVERT(NVARCHAR(10), @TotalRules)
    + N', open-to-internet(0.0.0.0-255.255.255.255)=' + CONVERT(NVARCHAR(10), @OpenToWorld)
    + N', wide-range=' + CONVERT(NVARCHAR(10), @WideRanges)
    + N', allow-all-Azure-services(0.0.0.0-0.0.0.0)=' + CONVERT(NVARCHAR(10), @AzureServices)
    + N', narrow=' + CONVERT(NVARCHAR(10), @NarrowRules)
    + CASE WHEN @RuleList IS NULL THEN N'.' ELSE N'. First rules: ' + @RuleList + N'.' END;

IF @EngineEdition NOT IN (5, 6, 11)
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Not applicable: EngineEdition ' + CONVERT(NVARCHAR(10), @EngineEdition)
                 + N' is not Azure SQL Database or Azure Synapse SQL, so the Azure public network access control does not apply to this instance.';
END
ELSE IF @OpenToWorld > 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'The public endpoint is open to the entire internet: ' + CONVERT(NVARCHAR(10), @OpenToWorld)
                 + N' firewall rule(s) allow 0.0.0.0-255.255.255.255. ' + @RuleSummary;
END
ELSE IF @WideRanges > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Public network access is enabled and ' + CONVERT(NVARCHAR(10), @WideRanges)
                 + N' firewall rule(s) allow a wide address range spanning multiple first octets, which is not a tight restriction. ' + @RuleSummary;
END
ELSE IF @AzureServices > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'No internet-wide rule exists, but the allow-all-Azure-services rule (0.0.0.0-0.0.0.0) is present, which admits traffic from any Azure subscription. ' + @RuleSummary;
END
ELSE IF @TotalRules = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No server-level or database-level firewall rules exist, so the public endpoint accepts no traffic; this is consistent with public network access being disabled or private-endpoint only. ' + @RuleSummary;
END
ELSE
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Public access is tightly restricted: all ' + CONVERT(NVARCHAR(10), @TotalRules)
                 + N' firewall rule(s) are narrow ranges confined to a single first octet, with no internet-wide or allow-all-Azure-services rule. ' + @RuleSummary;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #FirewallRules;