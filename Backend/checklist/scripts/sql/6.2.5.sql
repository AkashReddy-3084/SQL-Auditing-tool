SET NOCOUNT ON;

DECLARE @IsAzureSqlDb        bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion        int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @RlsSupported        bit = 0;

IF @IsAzureSqlDb = 1 OR (@MajorVersion IS NOT NULL AND @MajorVersion >= 13)
    SET @RlsSupported = 1;

IF OBJECT_ID('tempdb..#RlsFindings') IS NOT NULL
    DROP TABLE #RlsFindings;

CREATE TABLE #RlsFindings
(
    DatabaseName        sysname        NOT NULL,
    PolicyCount         int            NULL,
    EnabledPolicyCount  int            NULL,
    SchemaboundCount    int            NULL,
    FilterPredicates    int            NULL,
    BlockPredicates     int            NULL,
    PolicyList          nvarchar(2000) NULL
);

DECLARE @db      sysname;
DECLARE @prefix  nvarchar(300);
DECLARE @sql     nvarchar(max);

IF @RlsSupported = 1
BEGIN
    DECLARE @DbList TABLE (DatabaseName sysname NOT NULL);

    IF @IsAzureSqlDb = 1
    BEGIN
        INSERT INTO @DbList (DatabaseName)
        SELECT DB_NAME()
        WHERE DB_NAME() NOT IN (N'master', N'tempdb', N'model', N'msdb');
    END
    ELSE
    BEGIN
        INSERT INTO @DbList (DatabaseName)
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1;
    END;

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM @DbList ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        SET @sql = N'
INSERT INTO #RlsFindings
    (DatabaseName, PolicyCount, EnabledPolicyCount, SchemaboundCount, FilterPredicates, BlockPredicates, PolicyList)
SELECT
    @dbname,
    COUNT(DISTINCT sp.object_id),
    COUNT(DISTINCT CASE WHEN sp.is_enabled = 1 THEN sp.object_id END),
    COUNT(DISTINCT CASE WHEN sp.is_schema_bound = 1 THEN sp.object_id END),
    SUM(CASE WHEN pr.predicate_type = 0 THEN 1 ELSE 0 END),
    SUM(CASE WHEN pr.predicate_type = 1 THEN 1 ELSE 0 END),
    STUFF((SELECT TOP (10) N'', '' + QUOTENAME(sch.name) + N''.'' + QUOTENAME(pol.name)
                          + CASE WHEN pol.is_enabled = 1 THEN N'' (enabled)'' ELSE N'' (DISABLED)'' END
           FROM ' + @prefix + N'sys.security_policies AS pol
           INNER JOIN ' + @prefix + N'sys.schemas AS sch
                   ON sch.schema_id = pol.schema_id
           WHERE pol.is_ms_shipped = 0
           ORDER BY pol.name
           FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(2000)''), 1, 2, N'''')
FROM ' + @prefix + N'sys.security_policies AS sp
LEFT JOIN ' + @prefix + N'sys.security_predicates AS pr
       ON pr.object_id = sp.object_id
WHERE sp.is_ms_shipped = 0;';

        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@dbname sysname', @dbname = @db;
        END TRY
        BEGIN CATCH
            INSERT INTO #RlsFindings
                (DatabaseName, PolicyCount, EnabledPolicyCount, SchemaboundCount, FilterPredicates, BlockPredicates, PolicyList)
            VALUES (@db, NULL, NULL, NULL, NULL, NULL, N'Metadata not readable: ' + LEFT(ERROR_MESSAGE(), 200));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @db;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END;

DECLARE @TotalDbs         int = 0;
DECLARE @DbsWithEnabled   int = 0;
DECLARE @DbsDisabledOnly  int = 0;
DECLARE @TotalPolicies    int = 0;
DECLARE @TotalEnabled     int = 0;
DECLARE @TotalFilter      int = 0;
DECLARE @TotalBlock       int = 0;
DECLARE @NotSchemabound   int = 0;

SELECT
    @TotalDbs        = COUNT(*),
    @DbsWithEnabled  = SUM(CASE WHEN ISNULL(EnabledPolicyCount, 0) > 0 THEN 1 ELSE 0 END),
    @DbsDisabledOnly = SUM(CASE WHEN ISNULL(PolicyCount, 0) > 0 AND ISNULL(EnabledPolicyCount, 0) = 0 THEN 1 ELSE 0 END),
    @TotalPolicies   = SUM(ISNULL(PolicyCount, 0)),
    @TotalEnabled    = SUM(ISNULL(EnabledPolicyCount, 0)),
    @TotalFilter     = SUM(ISNULL(FilterPredicates, 0)),
    @TotalBlock      = SUM(ISNULL(BlockPredicates, 0)),
    @NotSchemabound  = SUM(ISNULL(PolicyCount, 0) - ISNULL(SchemaboundCount, 0))
FROM #RlsFindings;

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #RlsFindings
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @EnabledDbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #RlsFindings
                  WHERE ISNULL(EnabledPolicyCount, 0) > 0
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @DisabledDbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #RlsFindings
                  WHERE ISNULL(PolicyCount, 0) > 0 AND ISNULL(EnabledPolicyCount, 0) = 0
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @RlsSupported = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Row-Level Security is not supported by this engine (ProductVersion '
                 + ISNULL(CONVERT(nvarchar(50), SERVERPROPERTY('ProductVersion')), N'unknown')
                 + N'). RLS requires SQL Server 2016 (major version 13) or later, or Azure SQL Database, '
                 + N'so no segmented access enforcement can exist at the database engine layer.';
END
ELSE IF @TotalDbs = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user database was accessible to the audit login, so Row-Level Security implementation could not be assessed. '
                 + N'Re-run with a login that has CONNECT and VIEW DEFINITION rights on the application databases.';
END
ELSE IF @DbsWithEnabled > 0 AND @DbsDisabledOnly = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Row-Level Security is implemented and active: ' + CONVERT(nvarchar(10), @TotalEnabled)
                 + N' of ' + CONVERT(nvarchar(10), @TotalPolicies) + N' security policies are enabled across '
                 + CONVERT(nvarchar(10), @DbsWithEnabled) + N' of ' + CONVERT(nvarchar(10), @TotalDbs)
                 + N' user database(s) [' + @EnabledDbList + N']. Predicates: '
                 + CONVERT(nvarchar(10), @TotalFilter) + N' FILTER, ' + CONVERT(nvarchar(10), @TotalBlock) + N' BLOCK. '
                 + CASE WHEN @NotSchemabound > 0
                        THEN CONVERT(nvarchar(10), @NotSchemabound) + N' policy(ies) are not SCHEMABINDING-bound. '
                        ELSE N'All policies are schema-bound. ' END
                 + N'No database was found with policies defined but fully disabled.';
END
ELSE IF @DbsWithEnabled > 0 AND @DbsDisabledOnly > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Row-Level Security is only partially active. Enabled policies exist in [' + @EnabledDbList
                 + N'], but database(s) [' + @DisabledDbList + N'] have security policies defined that are ALL disabled. '
                 + N'Totals: ' + CONVERT(nvarchar(10), @TotalEnabled) + N' enabled of '
                 + CONVERT(nvarchar(10), @TotalPolicies) + N' policies; '
                 + CONVERT(nvarchar(10), @TotalFilter) + N' FILTER and ' + CONVERT(nvarchar(10), @TotalBlock)
                 + N' BLOCK predicates. Confirm whether the disabled policies protect data that requires segmented access.';
END
ELSE IF @TotalPolicies > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Row-Level Security policies are defined but NONE are enabled. '
                 + CONVERT(nvarchar(10), @TotalPolicies) + N' policy(ies) exist in database(s) ['
                 + @DisabledDbList + N'] with is_enabled = 0, so no row filtering or blocking is enforced at runtime '
                 + N'and every caller currently sees all rows in the intended protected tables.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'No Row-Level Security policy exists in any of the ' + CONVERT(nvarchar(10), @TotalDbs)
                 + N' accessible user database(s) [' + @DatabaseQueried + N'] - sys.security_policies returned no user-defined rows. '
                 + N'If any of these databases host multi-tenant or segmented data, RLS is not implemented and access segregation '
                 + N'depends entirely on application logic or per-object permissions.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#RlsFindings') IS NOT NULL
    DROP TABLE #RlsFindings;