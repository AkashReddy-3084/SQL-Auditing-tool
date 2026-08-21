/* Checklist 6.3.1 - Firewall / network rules restrict access to known sources
   Read-only. Scope: SERVER. */
SET NOCOUNT ON;

DECLARE @EngineEdition    INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried  NVARCHAR(128)  = DB_NAME();
DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT;
DECLARE @Finding          NVARCHAR(MAX);
DECLARE @Sql              NVARCHAR(MAX);
DECLARE @ReadError        NVARCHAR(4000) = NULL;
DECLARE @SourcesRead      INT            = 0;
DECLARE @Total            INT            = 0;
DECLARE @AllowAllInternet INT            = 0;
DECLARE @AllowAzureSvcs   INT            = 0;
DECLARE @BroadRules       INT            = 0;
DECLARE @NarrowRules      INT            = 0;
DECLARE @OffendingNames   NVARCHAR(MAX)  = NULL;
DECLARE @AllNames         NVARCHAR(MAX)  = NULL;

DECLARE @Rules TABLE
(
    RuleScope NVARCHAR(20)  NOT NULL,
    RuleName  NVARCHAR(256) NULL,
    StartIp   NVARCHAR(64)  NULL,
    EndIp     NVARCHAR(64)  NULL
);

DECLARE @Calc TABLE
(
    RuleScope    NVARCHAR(20)  NOT NULL,
    RuleName     NVARCHAR(256) NULL,
    StartIp      NVARCHAR(64)  NULL,
    EndIp        NVARCHAR(64)  NULL,
    AddressCount BIGINT        NULL,
    RuleKind     NVARCHAR(20)  NOT NULL
);

IF @EngineEdition = 5   /* Azure SQL Database - firewall rules are exposed to T-SQL */
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT ''Server'', CONVERT(NVARCHAR(256), name), CONVERT(NVARCHAR(64), start_ip_address), CONVERT(NVARCHAR(64), end_ip_address) FROM sys.firewall_rules;';
            INSERT INTO @Rules (RuleScope, RuleName, StartIp, EndIp)
            EXEC sp_executesql @Sql;
            SET @SourcesRead = @SourcesRead + 1;
        END

        IF OBJECT_ID('sys.database_firewall_rules') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT ''Database'', CONVERT(NVARCHAR(256), name), CONVERT(NVARCHAR(64), start_ip_address), CONVERT(NVARCHAR(64), end_ip_address) FROM sys.database_firewall_rules;';
            INSERT INTO @Rules (RuleScope, RuleName, StartIp, EndIp)
            EXEC sp_executesql @Sql;
            SET @SourcesRead = @SourcesRead + 1;
        END
    END TRY
    BEGIN CATCH
        SET @ReadError = ERROR_MESSAGE();
    END CATCH

    INSERT INTO @Calc (RuleScope, RuleName, StartIp, EndIp, AddressCount, RuleKind)
    SELECT
        x.RuleScope,
        x.RuleName,
        x.StartIp,
        x.EndIp,
        CASE
            WHEN x.StartNum IS NULL OR x.EndNum IS NULL OR x.EndNum < x.StartNum THEN NULL
            ELSE (x.EndNum - x.StartNum + 1)
        END,
        CASE
            WHEN ISNULL(x.StartIp, N'') = N'0.0.0.0' AND ISNULL(x.EndIp, N'') = N'255.255.255.255' THEN N'AllowAllInternet'
            WHEN ISNULL(x.StartIp, N'') = N'0.0.0.0' AND ISNULL(x.EndIp, N'') = N'0.0.0.0'         THEN N'AllowAzureServices'
            WHEN x.StartNum IS NULL OR x.EndNum IS NULL OR x.EndNum < x.StartNum                   THEN N'Unparsed'
            WHEN (x.EndNum - x.StartNum + 1) > 256                                                 THEN N'Broad'
            ELSE N'Narrow'
        END
    FROM
    (
        SELECT
            r.RuleScope,
            r.RuleName,
            r.StartIp,
            r.EndIp,
              (TRY_CAST(PARSENAME(r.StartIp, 4) AS BIGINT) * 16777216)
            + (TRY_CAST(PARSENAME(r.StartIp, 3) AS BIGINT) * 65536)
            + (TRY_CAST(PARSENAME(r.StartIp, 2) AS BIGINT) * 256)
            +  TRY_CAST(PARSENAME(r.StartIp, 1) AS BIGINT)  AS StartNum,
              (TRY_CAST(PARSENAME(r.EndIp, 4) AS BIGINT) * 16777216)
            + (TRY_CAST(PARSENAME(r.EndIp, 3) AS BIGINT) * 65536)
            + (TRY_CAST(PARSENAME(r.EndIp, 2) AS BIGINT) * 256)
            +  TRY_CAST(PARSENAME(r.EndIp, 1) AS BIGINT)    AS EndNum
        FROM @Rules AS r
    ) AS x;

    SET @Total            = (SELECT COUNT(*) FROM @Calc);
    SET @AllowAllInternet = (SELECT COUNT(*) FROM @Calc WHERE RuleKind = N'AllowAllInternet');
    SET @AllowAzureSvcs   = (SELECT COUNT(*) FROM @Calc WHERE RuleKind = N'AllowAzureServices');
    SET @BroadRules       = (SELECT COUNT(*) FROM @Calc WHERE RuleKind IN (N'Broad', N'Unparsed'));
    SET @NarrowRules      = (SELECT COUNT(*) FROM @Calc WHERE RuleKind = N'Narrow');

    SET @OffendingNames = STUFF((
        SELECT N'; ' + c.RuleScope + N':' + ISNULL(c.RuleName, N'(unnamed)')
               + N' [' + ISNULL(c.StartIp, N'?') + N' - ' + ISNULL(c.EndIp, N'?') + N']'
               + N' (' + c.RuleKind + N')'
        FROM @Calc AS c
        WHERE c.RuleKind IN (N'AllowAllInternet', N'Broad', N'Unparsed', N'AllowAzureServices')
        ORDER BY c.RuleScope, c.RuleName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SET @AllNames = STUFF((
        SELECT N'; ' + c.RuleScope + N':' + ISNULL(c.RuleName, N'(unnamed)')
               + N' [' + ISNULL(c.StartIp, N'?') + N' - ' + ISNULL(c.EndIp, N'?') + N']'
        FROM @Calc AS c
        ORDER BY c.RuleScope, c.RuleName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
END

IF @EngineEdition <> 5
BEGIN
    SET @Score   = 1;
    SET @Finding = N'EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N' (' + ISNULL(CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)), N'unknown edition')
                 + N'): network access to this instance is enforced outside the database engine (Windows Firewall, network security groups, subnet / private endpoint rules) and no firewall catalog is exposed to T-SQL, so restriction to known sources cannot be evidenced from the engine. Manually confirm that inbound rules for the SQL listener port permit only known source addresses.';
END
ELSE IF @ReadError IS NOT NULL
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Azure SQL Database detected, but the firewall rule catalogs could not be read: ' + @ReadError
                 + N'. Restriction to known sources could not be evidenced. Re-run with a login that can read sys.firewall_rules in master and sys.database_firewall_rules.';
END
ELSE IF @SourcesRead = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Azure SQL Database detected, but neither sys.firewall_rules nor sys.database_firewall_rules is visible from database [' + @DatabaseQueried
                 + N']. Restriction to known sources could not be evidenced. Connect to master with sufficient permissions to enumerate server-level firewall rules.';
END
ELSE IF @AllowAllInternet > 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Firewall rules open the service to the entire internet: ' + CAST(@AllowAllInternet AS NVARCHAR(10))
                 + N' rule(s) span 0.0.0.0 - 255.255.255.255. Offending rule(s): ' + ISNULL(@OffendingNames, N'(none listed)')
                 + N'. Total rules examined: ' + CAST(@Total AS NVARCHAR(10)) + N'.';
END
ELSE IF @BroadRules > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Access is not limited to known sources: ' + CAST(@BroadRules AS NVARCHAR(10))
                 + N' firewall rule(s) cover more than 256 addresses or have an unparseable range. Offending rule(s): ' + ISNULL(@OffendingNames, N'(none listed)')
                 + N'. Narrow rules: ' + CAST(@NarrowRules AS NVARCHAR(10))
                 + N'; Allow-Azure-services rules: ' + CAST(@AllowAzureSvcs AS NVARCHAR(10))
                 + N'; total rules examined: ' + CAST(@Total AS NVARCHAR(10)) + N'.';
END
ELSE IF @AllowAzureSvcs > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'All ' + CAST(@NarrowRules AS NVARCHAR(10)) + N' explicit firewall rule(s) are narrowly scoped, but the "Allow Azure services and resources to access this server" rule (0.0.0.0 - 0.0.0.0) is enabled, which admits traffic from any Azure tenant rather than known sources. Rules: '
                 + ISNULL(@AllNames, N'(none)') + N'.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No server-level or database-level firewall rules are defined, so no public source address is permitted; connectivity is restricted to private endpoint / VNet paths only. Firewall catalogs read: ' + CAST(@SourcesRead AS NVARCHAR(10)) + N'.';
END
ELSE
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10)) + N' firewall rule(s) are restricted to known sources (each range covers 256 addresses or fewer) and the "Allow Azure services" rule is not enabled. Rules: '
                 + ISNULL(@AllNames, N'(none)') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;