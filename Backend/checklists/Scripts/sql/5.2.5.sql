SET NOCOUNT ON;

/* Checklist 5.2.5 - Null/empty handling: unexpected nulls flagged. Read-only metadata inspection. */

IF OBJECT_ID('tempdb..#NullHandling') IS NOT NULL DROP TABLE #NullHandling;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;

CREATE TABLE #NullHandling
(
    DatabaseName      sysname NOT NULL,
    TotalColumns      int     NOT NULL,
    NotNullColumns    int     NOT NULL,
    NullableNoDefault int     NOT NULL,
    NullGuardChecks   int     NOT NULL,
    NullableDefaults  int     NOT NULL,
    DqObjects         int     NOT NULL
);

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @Template nvarchar(max);
DECLARE @Sql      nvarchar(max);
DECLARE @DbName   sysname;

SET @Template = N'
SELECT
    N''{D}'' AS DatabaseName,
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0) AS TotalColumns,
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0 AND c.is_nullable = 0) AS NotNullColumns,
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0 AND c.is_nullable = 1 AND c.default_object_id = 0) AS NullableNoDefault,
    (SELECT COUNT(*)
       FROM {P}sys.check_constraints cc
      WHERE cc.is_disabled = 0
        AND (cc.definition LIKE ''%IS NOT NULL%''
          OR cc.definition LIKE ''%IS NULL%''
          OR cc.definition LIKE ''%ISNULL%''
          OR cc.definition LIKE ''%COALESCE%''
          OR cc.definition LIKE ''%NULLIF%''
          OR cc.definition LIKE ''%LEN(%'')) AS NullGuardChecks,
    (SELECT COUNT(*)
       FROM {P}sys.columns c
       INNER JOIN {P}sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0 AND c.is_nullable = 1 AND c.default_object_id <> 0) AS NullableDefaults,
    (SELECT COUNT(*)
       FROM {P}sys.objects o
      WHERE o.is_ms_shipped = 0
        AND o.type IN (''P'',''FN'',''TF'',''IF'',''V'',''TR'')
        AND (o.name LIKE ''%null%''
          OR o.name LIKE ''%dataqual%''
          OR o.name LIKE ''%data[_]qual%''
          OR o.name LIKE ''%dq[_]%''
          OR o.name LIKE ''%validat%''
          OR o.name LIKE ''%cleans%'')) AS DqObjects;';

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database queries are not possible, evaluate current context only. */
    SET @Sql = REPLACE(REPLACE(@Template, N'{P}', N''), N'{D}', REPLACE(DB_NAME(), CHAR(39), CHAR(39) + CHAR(39)));

    BEGIN TRY
        INSERT INTO #NullHandling
            (DatabaseName, TotalColumns, NotNullColumns, NullableNoDefault, NullGuardChecks, NullableDefaults, DqObjects)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* database not readable - excluded from evaluation */
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.source_database_id IS NULL
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(REPLACE(@Template, N'{P}', QUOTENAME(@DbName) + N'.'), N'{D}', REPLACE(@DbName, CHAR(39), CHAR(39) + CHAR(39)));

        BEGIN TRY
            INSERT INTO #NullHandling
                (DatabaseName, TotalColumns, NotNullColumns, NullableNoDefault, NullGuardChecks, NullableDefaults, DqObjects)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* database not readable - excluded from evaluation */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SELECT
    n.DatabaseName,
    n.TotalColumns,
    n.NullableNoDefault,
    CAST(n.NotNullColumns * 100.0 / n.TotalColumns AS decimal(5,1)) AS NotNullPct,
    (n.NullGuardChecks + n.NullableDefaults + n.DqObjects) AS GuardCount,
    CAST(CASE
            WHEN (n.NotNullColumns * 100.0 / n.TotalColumns) >= 60
                 AND (n.NullGuardChecks + n.NullableDefaults + n.DqObjects) > 0 THEN 'Compliant'
            WHEN (n.NotNullColumns * 100.0 / n.TotalColumns) >= 40
                 OR (n.NullGuardChecks + n.NullableDefaults + n.DqObjects) > 0 THEN 'Partial'
            ELSE 'Weak'
         END AS varchar(10)) AS DbStatus
INTO #Scored
FROM #NullHandling n
WHERE n.TotalColumns > 0;

DECLARE @Evaluated int, @Compliant int, @Partial int, @Weak int;
DECLARE @DbList nvarchar(max), @WeakList nvarchar(max), @PartialList nvarchar(max);
DECLARE @Result varchar(30), @Finding nvarchar(max), @DatabaseQueried nvarchar(max);
DECLARE @Score int;

SELECT @Evaluated = COUNT(*),
       @Compliant = SUM(CASE WHEN DbStatus = 'Compliant' THEN 1 ELSE 0 END),
       @Partial   = SUM(CASE WHEN DbStatus = 'Partial'   THEN 1 ELSE 0 END),
       @Weak      = SUM(CASE WHEN DbStatus = 'Weak'      THEN 1 ELSE 0 END)
FROM #Scored;

SET @Evaluated = ISNULL(@Evaluated, 0);
SET @Compliant = ISNULL(@Compliant, 0);
SET @Partial   = ISNULL(@Partial, 0);
SET @Weak      = ISNULL(@Weak, 0);

SET @DbList = STUFF((SELECT N', ' + s.DatabaseName
                       FROM #Scored s
                      ORDER BY s.DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @WeakList = STUFF((SELECT N', ' + s.DatabaseName
                         FROM #Scored s
                        WHERE s.DbStatus = 'Weak'
                        ORDER BY s.DatabaseName
                          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @PartialList = STUFF((SELECT N', ' + s.DatabaseName
                            FROM #Scored s
                           WHERE s.DbStatus = 'Partial'
                           ORDER BY s.DatabaseName
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @Evaluated = 0
BEGIN
    SET @Score = 1;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No accessible user database containing user tables was found, so null/empty handling enforcement could not be assessed. Manual review of the data quality rules is required.';
END
ELSE IF @Weak = 0 AND @Partial = 0
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = LEFT(@DbList, 500);
    SET @Finding = N'All ' + CAST(@Evaluated AS nvarchar(10)) + N' evaluated user database(s) enforce null/empty handling: NOT NULL coverage is at least 60% of user-table columns and each database contains explicit null guards (null-related CHECK constraints, DEFAULT constraints on nullable columns, or data-quality validation objects). Databases: ' + LEFT(@DbList, 500) + N'.';
END
ELSE IF @Weak = 0
BEGIN
    SET @Score = 2;
    SET @DatabaseQueried = LEFT(@DbList, 500);
    SET @Finding = N'Null/empty handling is enforced but only partially. Of ' + CAST(@Evaluated AS nvarchar(10)) + N' evaluated database(s), ' + CAST(@Compliant AS nvarchar(10)) + N' are fully compliant and ' + CAST(@Partial AS nvarchar(10)) + N' show partial enforcement (limited NOT NULL coverage or few explicit null guards): ' + LEFT(ISNULL(@PartialList, N'n/a'), 400) + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @DatabaseQueried = LEFT(@DbList, 500);
    SET @Finding = N'Unexpected NULLs are not flagged or prevented. Of ' + CAST(@Evaluated AS nvarchar(10)) + N' evaluated database(s), ' + CAST(@Weak AS nvarchar(10)) + N' have effectively no null/empty handling (NOT NULL coverage below 40% and no null-related CHECK constraints, nullable-column defaults or data-quality validation objects): ' + LEFT(ISNULL(@WeakList, N'n/a'), 400) + N'. Partial: ' + CAST(@Partial AS nvarchar(10)) + N', Compliant: ' + CAST(@Compliant AS nvarchar(10)) + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;