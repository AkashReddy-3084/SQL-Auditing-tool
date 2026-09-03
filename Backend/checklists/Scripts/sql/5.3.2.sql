/*
    Checklist Item : 5.3.2 - Business rule validation applied (domain rules, ranges)
    Scope          : DATABASE
    Description    : Read-only inspection of CHECK constraints, DEFAULT constraints and
                     validation triggers on user tables across all accessible user databases.
    Read-only      : Queries system catalog views only. No data or schema is modified.
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DbRules') IS NOT NULL
    DROP TABLE #DbRules;

CREATE TABLE #DbRules
(
    DatabaseName            SYSNAME       NOT NULL,
    UserTableCount          INT           NOT NULL,
    TablesWithCheck         INT           NOT NULL,
    CheckConstraintCount    INT           NOT NULL,
    RangeCheckCount         INT           NOT NULL,
    DefaultConstraintCount  INT           NOT NULL,
    ValidationTriggerCount  INT           NOT NULL
);

DECLARE @IsAzureDb        BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DbName           SYSNAME;
DECLARE @Sql              NVARCHAR(MAX);

DECLARE @Databases TABLE (DatabaseName SYSNAME NOT NULL);

IF @IsAzureDb = 1
BEGIN
    /* Azure SQL Database: cross-database queries are not supported, evaluate the current database only. */
    INSERT INTO @Databases (DatabaseName)
    VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO @Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
        SELECT
            @DbIn AS DatabaseName,
            (SELECT COUNT(*)
             FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
             WHERE t.is_ms_shipped = 0) AS UserTableCount,
            (SELECT COUNT(DISTINCT cc.parent_object_id)
             FROM ' + QUOTENAME(@DbName) + N'.sys.check_constraints AS cc
             INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t2
                 ON t2.object_id = cc.parent_object_id
             WHERE t2.is_ms_shipped = 0
               AND cc.is_disabled = 0) AS TablesWithCheck,
            (SELECT COUNT(*)
             FROM ' + QUOTENAME(@DbName) + N'.sys.check_constraints AS cc2
             INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t3
                 ON t3.object_id = cc2.parent_object_id
             WHERE t3.is_ms_shipped = 0
               AND cc2.is_disabled = 0) AS CheckConstraintCount,
            (SELECT COUNT(*)
             FROM ' + QUOTENAME(@DbName) + N'.sys.check_constraints AS cc3
             INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t4
                 ON t4.object_id = cc3.parent_object_id
             WHERE t4.is_ms_shipped = 0
               AND cc3.is_disabled = 0
               AND (cc3.definition LIKE ''%>%''
                 OR cc3.definition LIKE ''%<%''
                 OR cc3.definition LIKE ''%BETWEEN%''
                 OR cc3.definition LIKE ''% IN %''
                 OR cc3.definition LIKE ''%LIKE%'')) AS RangeCheckCount,
            (SELECT COUNT(*)
             FROM ' + QUOTENAME(@DbName) + N'.sys.default_constraints AS dc
             INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t5
                 ON t5.object_id = dc.parent_object_id
             WHERE t5.is_ms_shipped = 0) AS DefaultConstraintCount,
            (SELECT COUNT(*)
             FROM ' + QUOTENAME(@DbName) + N'.sys.triggers AS tr
             INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t6
                 ON t6.object_id = tr.parent_id
             WHERE t6.is_ms_shipped = 0
               AND tr.is_ms_shipped = 0
               AND tr.is_disabled = 0) AS ValidationTriggerCount;';

        INSERT INTO #DbRules
        (
            DatabaseName, UserTableCount, TablesWithCheck, CheckConstraintCount,
            RangeCheckCount, DefaultConstraintCount, ValidationTriggerCount
        )
        EXEC sp_executesql @Sql, N'@DbIn SYSNAME', @DbIn = @DbName;
    END TRY
    BEGIN CATCH
        /* Database inaccessible (offline, restoring, permissions) - skip and continue. */
        SET @Sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbCount              INT;
DECLARE @DbWithTables         INT;
DECLARE @TotalTables          INT;
DECLARE @TotalTablesWithCheck INT;
DECLARE @TotalChecks          INT;
DECLARE @TotalRangeChecks     INT;
DECLARE @TotalDefaults        INT;
DECLARE @TotalTriggers        INT;
DECLARE @Coverage             DECIMAL(9, 2);
DECLARE @Score                INT;
DECLARE @Result               NVARCHAR(20);
DECLARE @Finding              NVARCHAR(MAX);
DECLARE @DatabaseQueried      NVARCHAR(MAX);
DECLARE @NoValidationList     NVARCHAR(MAX);

SELECT
    @DbCount              = COUNT(*),
    @DbWithTables         = SUM(CASE WHEN UserTableCount > 0 THEN 1 ELSE 0 END),
    @TotalTables          = ISNULL(SUM(UserTableCount), 0),
    @TotalTablesWithCheck = ISNULL(SUM(TablesWithCheck), 0),
    @TotalChecks          = ISNULL(SUM(CheckConstraintCount), 0),
    @TotalRangeChecks     = ISNULL(SUM(RangeCheckCount), 0),
    @TotalDefaults        = ISNULL(SUM(DefaultConstraintCount), 0),
    @TotalTriggers        = ISNULL(SUM(ValidationTriggerCount), 0)
FROM #DbRules;

SET @DbCount      = ISNULL(@DbCount, 0);
SET @DbWithTables = ISNULL(@DbWithTables, 0);

SET @DatabaseQueried = STUFF((
        SELECT N', ' + r.DatabaseName
        FROM #DbRules AS r
        ORDER BY r.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @NoValidationList = STUFF((
        SELECT N', ' + r.DatabaseName
        FROM #DbRules AS r
        WHERE r.UserTableCount > 0
          AND r.TablesWithCheck = 0
        ORDER BY r.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'None');

SET @Coverage = CASE
                    WHEN @TotalTables = 0 THEN 0.00
                    ELSE CAST(@TotalTablesWithCheck * 100.0 / @TotalTables AS DECIMAL(9, 2))
                END;

IF @DbCount = 0 OR @TotalTables = 0
BEGIN
    SET @Score  = 0;
    SET @Result = N'NeedsReview';
    SET @Finding = N'No accessible user database containing user tables was found (databases inspected: '
                   + @DatabaseQueried
                   + N'). Business rule validation coverage could not be measured from schema metadata and requires manual review.';
END
ELSE
BEGIN
    IF @Coverage >= 70.00 AND @TotalRangeChecks > 0
        SET @Score = 3;
    ELSE IF @Coverage >= 40.00
        SET @Score = 2;
    ELSE IF @TotalChecks > 0 OR @TotalTriggers > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding = N'Across ' + CAST(@DbCount AS NVARCHAR(10)) + N' accessible user database(s) ('
                   + CAST(@DbWithTables AS NVARCHAR(10)) + N' containing user tables), '
                   + CAST(@TotalTablesWithCheck AS NVARCHAR(10)) + N' of '
                   + CAST(@TotalTables AS NVARCHAR(10)) + N' user tables ('
                   + CAST(@Coverage AS NVARCHAR(20)) + N'%) have at least one enabled CHECK constraint. '
                   + N'Enabled CHECK constraints: ' + CAST(@TotalChecks AS NVARCHAR(10))
                   + N' (of which ' + CAST(@TotalRangeChecks AS NVARCHAR(10))
                   + N' express a domain/range predicate such as >, <, BETWEEN, IN or LIKE). '
                   + N'DEFAULT constraints: ' + CAST(@TotalDefaults AS NVARCHAR(10))
                   + N'. Enabled user DML triggers on user tables: ' + CAST(@TotalTriggers AS NVARCHAR(10)) + N'.'
                   + CASE
                         WHEN @NoValidationList IS NOT NULL
                             THEN N' Databases with user tables but no enabled CHECK constraint: ' + @NoValidationList + N'.'
                         ELSE N' Every database containing user tables has at least one enabled CHECK constraint.'
                     END
                   + CASE
                         WHEN @Score = 3 THEN N' Domain and range business rules are enforced declaratively at an adequate level.'
                         WHEN @Score = 2 THEN N' Business rule validation is only partially applied; a substantial share of user tables carries no declarative domain or range enforcement.'
                         WHEN @Score = 1 THEN N' Business rule validation is minimal; the large majority of user tables rely entirely on application-side enforcement.'
                         ELSE N' No enabled CHECK constraints or validation triggers were found; no declarative business rule validation is applied.'
                     END;
END

IF OBJECT_ID('tempdb..#DbRules') IS NOT NULL
    DROP TABLE #DbRules;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;