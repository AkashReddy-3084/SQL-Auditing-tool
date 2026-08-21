SET NOCOUNT ON;

/* Checklist 3.1.3 - Schema-qualified object references (dbo.Table, not Table)
   Read-only. Uses sys.sql_expression_dependencies.referenced_schema_name, which is NULL
   when the referencing module did not schema-qualify a same-database object reference. */

DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#AuditDatabases') IS NOT NULL DROP TABLE #AuditDatabases;
IF OBJECT_ID('tempdb..#AuditFindings') IS NOT NULL DROP TABLE #AuditFindings;
IF OBJECT_ID('tempdb..#AuditSamples') IS NOT NULL DROP TABLE #AuditSamples;

CREATE TABLE #AuditDatabases
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

CREATE TABLE #AuditFindings
(
    DatabaseName           SYSNAME NOT NULL PRIMARY KEY,
    TotalRefs              INT     NOT NULL,
    UnqualifiedRefs        INT     NOT NULL,
    ModulesWithUnqualified INT     NOT NULL,
    TotalModules           INT     NOT NULL
);

CREATE TABLE #AuditSamples
(
    DatabaseName SYSNAME        NOT NULL,
    SampleText   NVARCHAR(500)  NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #AuditDatabases (DatabaseName)
    VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #AuditDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName SYSNAME;
DECLARE @Sql    NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #AuditDatabases ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT
    @pDb AS DatabaseName,
    COUNT(*) AS TotalRefs,
    ISNULL(SUM(CASE WHEN d.referenced_schema_name IS NULL THEN 1 ELSE 0 END), 0) AS UnqualifiedRefs,
    COUNT(DISTINCT CASE WHEN d.referenced_schema_name IS NULL THEN d.referencing_id END) AS ModulesWithUnqualified,
    (SELECT COUNT(*)
     FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS sm
     INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS mo
             ON mo.object_id = sm.object_id
     WHERE mo.is_ms_shipped = 0) AS TotalModules
FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies AS d
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
        ON o.object_id = d.referencing_id
WHERE d.referencing_class = 1
  AND d.referenced_class = 1
  AND d.referenced_minor_id = 0
  AND d.referenced_server_name IS NULL
  AND d.referenced_database_name IS NULL
  AND d.is_ambiguous = 0
  AND o.is_ms_shipped = 0;';

        INSERT INTO #AuditFindings (DatabaseName, TotalRefs, UnqualifiedRefs, ModulesWithUnqualified, TotalModules)
        EXEC sp_executesql @Sql, N'@pDb SYSNAME', @pDb = @DbName;

        SET @Sql = N'
SELECT TOP (5)
    @pDb AS DatabaseName,
    LEFT(QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) + N'' -> '' + d.referenced_entity_name, 500) AS SampleText
FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies AS d
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
        ON o.object_id = d.referencing_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
WHERE d.referencing_class = 1
  AND d.referenced_class = 1
  AND d.referenced_minor_id = 0
  AND d.referenced_server_name IS NULL
  AND d.referenced_database_name IS NULL
  AND d.is_ambiguous = 0
  AND d.referenced_schema_name IS NULL
  AND o.is_ms_shipped = 0
ORDER BY s.name, o.name, d.referenced_entity_name;';

        INSERT INTO #AuditSamples (DatabaseName, SampleText)
        EXEC sp_executesql @Sql, N'@pDb SYSNAME', @pDb = @DbName;
    END TRY
    BEGIN CATCH
        /* Database not readable by this login - excluded from the assessment. */
        DELETE FROM #AuditFindings WHERE DatabaseName = @DbName;
        DELETE FROM #AuditSamples  WHERE DatabaseName = @DbName;
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount        INT = (SELECT COUNT(*) FROM #AuditFindings);
DECLARE @AffectedDbs    INT = (SELECT COUNT(*) FROM #AuditFindings WHERE UnqualifiedRefs > 0);
DECLARE @TotalRefs      INT = (SELECT ISNULL(SUM(TotalRefs), 0) FROM #AuditFindings);
DECLARE @Unqualified    INT = (SELECT ISNULL(SUM(UnqualifiedRefs), 0) FROM #AuditFindings);
DECLARE @BadModules     INT = (SELECT ISNULL(SUM(ModulesWithUnqualified), 0) FROM #AuditFindings);
DECLARE @TotalModules   INT = (SELECT ISNULL(SUM(TotalModules), 0) FROM #AuditFindings);

DECLARE @Pct DECIMAL(9,2) =
    CASE WHEN @TotalRefs = 0 THEN CONVERT(DECIMAL(9,2), 0)
         ELSE CONVERT(DECIMAL(9,2), (@Unqualified * 100.0) / @TotalRefs)
    END;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + f.DatabaseName
           FROM #AuditFindings AS f
           ORDER BY f.DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @SampleList NVARCHAR(MAX) =
    STUFF((SELECT N'; ' + sp.DatabaseName + N': ' + sp.SampleText
           FROM #AuditSamples AS sp
           ORDER BY sp.DatabaseName, sp.SampleText
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT;
DECLARE @DatabaseQueried  NVARCHAR(500) = ISNULL(LEFT(@DbList, 500), N'None');
DECLARE @Finding          NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible online user database was found, so schema qualification of object references could not be assessed. Re-run with a login that has VIEW DEFINITION on the target databases.';
END
ELSE IF @TotalModules = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Databases examined (' + CONVERT(NVARCHAR(20), @DbCount) + N') contain no user-defined programmable objects (procedures, views, functions, triggers), so schema qualification of object references could not be evidenced from metadata.';
END
ELSE
BEGIN
    SET @Score =
        CASE
            WHEN @Unqualified = 0 THEN 3
            WHEN @Pct <= 5.00     THEN 2
            WHEN @Pct <= 20.00    THEN 1
            ELSE 0
        END;

    SET @Finding =
        N'Databases examined: ' + CONVERT(NVARCHAR(20), @DbCount)
      + N'. User-defined modules: ' + CONVERT(NVARCHAR(20), @TotalModules)
      + N'. Same-database object references resolved from module definitions: ' + CONVERT(NVARCHAR(20), @TotalRefs)
      + N'. References written without a schema qualifier: ' + CONVERT(NVARCHAR(20), @Unqualified)
      + N' (' + CONVERT(NVARCHAR(20), @Pct) + N'%)'
      + N', spanning ' + CONVERT(NVARCHAR(20), @BadModules) + N' module(s) in '
      + CONVERT(NVARCHAR(20), @AffectedDbs) + N' database(s).'
      + CASE WHEN @SampleList IS NULL THEN N''
             ELSE N' Examples (referencing object -> unqualified reference): ' + LEFT(@SampleList, 900)
        END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#AuditDatabases') IS NOT NULL DROP TABLE #AuditDatabases;
IF OBJECT_ID('tempdb..#AuditFindings') IS NOT NULL DROP TABLE #AuditFindings;
IF OBJECT_ID('tempdb..#AuditSamples') IS NOT NULL DROP TABLE #AuditSamples;