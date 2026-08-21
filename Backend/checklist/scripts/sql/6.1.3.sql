/* Checklist 6.1.3 - Database roles used for permission grants (not per-user grants)
   Read-only: catalog views only, no data or configuration is modified. */
SET NOCOUNT ON;

BEGIN TRY

    DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

    IF OBJECT_ID('tempdb..#GrantScan') IS NOT NULL
        DROP TABLE #GrantScan;

    CREATE TABLE #GrantScan
    (
        DatabaseName      sysname       NOT NULL,
        DirectUserGrants  int           NOT NULL,
        RoleGrants        int           NOT NULL,
        DirectGrantSample nvarchar(max) NULL
    );

    /* Per-database probe: counts permissions granted to users vs. granted to roles.
       CONNECT is excluded because it must be granted to the user principal itself. */
    DECLARE @InnerSql nvarchar(max) = N'
SELECT
    DB_NAME() AS DatabaseName,
    ISNULL(SUM(CASE WHEN pr.type IN (''S'',''U'',''G'',''E'',''X'') THEN 1 ELSE 0 END), 0) AS DirectUserGrants,
    ISNULL(SUM(CASE WHEN pr.type = ''R'' THEN 1 ELSE 0 END), 0) AS RoleGrants,
    ISNULL(STUFF((SELECT TOP (5) '', '' + s.name
                  FROM (SELECT DISTINCT pr2.name
                        FROM sys.database_permissions AS p2
                        INNER JOIN sys.database_principals AS pr2
                            ON pr2.principal_id = p2.grantee_principal_id
                        WHERE p2.state IN (''G'',''W'')
                          AND p2.permission_name <> ''CONNECT''
                          AND pr2.type IN (''S'',''U'',''G'',''E'',''X'')
                          AND pr2.principal_id > 4) AS s
                  ORDER BY s.name
                  FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, ''''), ''None'') AS DirectGrantSample
FROM sys.database_permissions AS perm
INNER JOIN sys.database_principals AS pr
    ON pr.principal_id = perm.grantee_principal_id
WHERE perm.state IN (''G'',''W'')
  AND perm.permission_name <> ''CONNECT''
  AND pr.principal_id > 4
  AND pr.is_fixed_role = 0;';

    IF @IsAzureSqlDb = 1
    BEGIN
        BEGIN TRY
            INSERT INTO #GrantScan (DatabaseName, DirectUserGrants, RoleGrants, DirectGrantSample)
            EXEC sp_executesql @InnerSql;
        END TRY
        BEGIN CATCH
            /* current database not readable - leave it out of the scan set */
        END CATCH
    END
    ELSE
    BEGIN
        DECLARE @DbName sysname;
        DECLARE @Sql nvarchar(max);

        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state_desc = 'ONLINE'
              AND d.source_database_id IS NULL
              AND d.is_in_standby = 0
              AND HAS_DBACCESS(d.name) = 1
            ORDER BY d.name;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @InnerSql;

                INSERT INTO #GrantScan (DatabaseName, DirectUserGrants, RoleGrants, DirectGrantSample)
                EXEC sp_executesql @Sql;
            END TRY
            BEGIN CATCH
                /* inaccessible / non-readable secondary - skipped */
            END CATCH

            FETCH NEXT FROM db_cur INTO @DbName;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    DECLARE @DbCount        int = (SELECT COUNT(*) FROM #GrantScan);
    DECLARE @TotalDirect    int = ISNULL((SELECT SUM(DirectUserGrants) FROM #GrantScan), 0);
    DECLARE @TotalRole      int = ISNULL((SELECT SUM(RoleGrants)       FROM #GrantScan), 0);
    DECLARE @DbsWithDirect  int = (SELECT COUNT(*) FROM #GrantScan WHERE DirectUserGrants > 0);
    DECLARE @DirectPct      decimal(9,2) =
        CASE WHEN (@TotalDirect + @TotalRole) = 0 THEN 0
             ELSE CONVERT(decimal(9,2), @TotalDirect) * 100.0 / (@TotalDirect + @TotalRole) END;

    DECLARE @DbList nvarchar(max) =
        ISNULL(STUFF((SELECT ', ' + g.DatabaseName
                      FROM #GrantScan AS g
                      ORDER BY g.DatabaseName
                      FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''), 'NONE');

    DECLARE @Details nvarchar(max) =
        ISNULL(STUFF((SELECT TOP (5) '; ' + g.DatabaseName + ' = ' + CAST(g.DirectUserGrants AS varchar(10))
                             + ' direct grant(s) to ' + g.DirectGrantSample
                      FROM #GrantScan AS g
                      WHERE g.DirectUserGrants > 0
                      ORDER BY g.DirectUserGrants DESC
                      FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''), '');

    DECLARE @Result   nvarchar(20);
    DECLARE @Score    int;
    DECLARE @Finding  nvarchar(max);

    IF @DbCount = 0
    BEGIN
        SET @Score  = 0;
        SET @Finding = 'No accessible online user database could be scanned, so permission grant practice could not be determined.';
    END
    ELSE IF @TotalDirect = 0
    BEGIN
        SET @Score  = 3;
        SET @Finding = 'All ' + CAST(@TotalRole AS varchar(10)) + ' explicit permission grant(s) across '
                     + CAST(@DbCount AS varchar(10)) + ' database(s) are made to database roles; no permission (other than CONNECT) is granted directly to a user principal.';
    END
    ELSE IF @DirectPct <= 20.0
    BEGIN
        SET @Score  = 2;
        SET @Finding = CAST(@TotalDirect AS varchar(10)) + ' permission grant(s) go directly to user principals in '
                     + CAST(@DbsWithDirect AS varchar(10)) + ' of ' + CAST(@DbCount AS varchar(10)) + ' database(s) ('
                     + CAST(@DirectPct AS varchar(20)) + '% of all grants; ' + CAST(@TotalRole AS varchar(10))
                     + ' grant(s) use roles). Examples: ' + @Details;
    END
    ELSE
    BEGIN
        SET @Score  = 1;
        SET @Finding = CAST(@TotalDirect AS varchar(10)) + ' permission grant(s) go directly to user principals in '
                     + CAST(@DbsWithDirect AS varchar(10)) + ' of ' + CAST(@DbCount AS varchar(10)) + ' database(s), '
                     + CAST(@DirectPct AS varchar(20)) + '% of all grants, versus only ' + CAST(@TotalRole AS varchar(10))
                     + ' grant(s) made through database roles. Examples: ' + @Details;
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result                       AS Result,
        @Score                        AS Score,
        LEFT(@DbList, 4000)           AS DatabaseQueried,
        LEFT(@Finding, 4000)          AS Finding;

    IF OBJECT_ID('tempdb..#GrantScan') IS NOT NULL
        DROP TABLE #GrantScan;

END TRY
BEGIN CATCH

    IF CURSOR_STATUS('local', 'db_cur') >= 0
    BEGIN
        CLOSE db_cur;
        DEALLOCATE db_cur;
    END
    ELSE IF CURSOR_STATUS('local', 'db_cur') = -1
    BEGIN
        DEALLOCATE db_cur;
    END

    SELECT
        'Fail'  AS Result,
        0       AS Score,
        'N/A'   AS DatabaseQueried,
        LEFT('Script execution failed: ' + ERROR_MESSAGE(), 4000) AS Finding;

END CATCH