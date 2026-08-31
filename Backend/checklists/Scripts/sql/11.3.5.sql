/* ============================================================================
   Checklist Item : 11.3.5 - Non-prod data masking/subsetting applied where sensitive
   Scope          : SERVER
   Type           : T-SQL (strictly read-only - catalog views only)
   Purpose        : Detect non-production databases (identified by naming
                    convention) that expose sensitive-looking columns without
                    Dynamic Data Masking applied.
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @MajorVersion  INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
DECLARE @DdmSupported  BIT = CASE WHEN ISNULL(@MajorVersion, 0) >= 13 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#NonProdPattern')   IS NOT NULL DROP TABLE #NonProdPattern;
IF OBJECT_ID('tempdb..#SensitivePattern') IS NOT NULL DROP TABLE #SensitivePattern;
IF OBJECT_ID('tempdb..#NonProdDatabases') IS NOT NULL DROP TABLE #NonProdDatabases;
IF OBJECT_ID('tempdb..#SensitiveColumns') IS NOT NULL DROP TABLE #SensitiveColumns;

CREATE TABLE #NonProdPattern
(
    Pattern NVARCHAR(64) COLLATE Latin1_General_CI_AS NOT NULL
);

CREATE TABLE #SensitivePattern
(
    Pattern NVARCHAR(64) COLLATE Latin1_General_CI_AS NOT NULL
);

CREATE TABLE #NonProdDatabases
(
    DatabaseName SYSNAME NOT NULL
);

CREATE TABLE #SensitiveColumns
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    TableName    SYSNAME NOT NULL,
    ColumnName   SYSNAME NOT NULL,
    IsMasked     BIT     NOT NULL
);

INSERT INTO #NonProdPattern (Pattern)
VALUES (N'%dev%'), (N'%test%'), (N'%tst%'), (N'%qa%'), (N'%uat%'), (N'%stag%'),
       (N'%sandbox%'), (N'%demo%'), (N'%train%'), (N'%preprod%'), (N'%pre_prod%'),
       (N'%pre-prod%'), (N'%nonprod%'), (N'%non_prod%'), (N'%non-prod%'), (N'%poc%');

INSERT INTO #SensitivePattern (Pattern)
VALUES (N'%ssn%'), (N'%social%security%'), (N'%nationalid%'), (N'%national_id%'),
       (N'%aadhaar%'), (N'%passport%'), (N'%driver%licen%'), (N'%creditcard%'),
       (N'%credit_card%'), (N'%cardnumber%'), (N'%card_number%'), (N'%cardno%'),
       (N'%cvv%'), (N'%iban%'), (N'%accountnumber%'), (N'%account_number%'),
       (N'%accountno%'), (N'%email%'), (N'%phone%'), (N'%mobile%'), (N'%dob%'),
       (N'%birth%'), (N'%salary%'), (N'%income%'), (N'%taxid%'), (N'%tax_id%'),
       (N'%password%'), (N'%passwd%'), (N'%pincode%'), (N'%postcode%'),
       (N'%address%'), (N'%firstname%'), (N'%first_name%'), (N'%lastname%'),
       (N'%last_name%'), (N'%fullname%'), (N'%full_name%'), (N'%surname%'),
       (N'%patient%'), (N'%medical%'), (N'%diagnos%');

/* ---- Identify candidate non-production databases -------------------------- */
IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: only the current database is reachable */
    INSERT INTO #NonProdDatabases (DatabaseName)
    SELECT DB_NAME()
    WHERE EXISTS
    (
        SELECT 1
        FROM #NonProdPattern AS p
        WHERE LOWER(DB_NAME()) COLLATE Latin1_General_CI_AS LIKE p.Pattern
    );
END
ELSE
BEGIN
    INSERT INTO #NonProdDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
      AND EXISTS
      (
          SELECT 1
          FROM #NonProdPattern AS p
          WHERE LOWER(d.name) COLLATE Latin1_General_CI_AS LIKE p.Pattern
      );
END

/* ---- Inspect sensitive columns and their masking state -------------------- */
DECLARE @Db      SYSNAME;
DECLARE @Sql     NVARCHAR(MAX);
DECLARE @MaskCol NVARCHAR(64) = CASE WHEN @DdmSupported = 1 THEN N'c.is_masked' ELSE N'CAST(0 AS BIT)' END;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #NonProdDatabases;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql =
        N'SELECT ' + QUOTENAME(@Db, '''') + N' AS DatabaseName,
                 s.name AS SchemaName,
                 t.name AS TableName,
                 c.name AS ColumnName,
                 CASE WHEN ' + @MaskCol + N' = 1 THEN 1 ELSE 0 END AS IsMasked
          FROM ' + QUOTENAME(@Db) + N'.sys.columns AS c
          INNER JOIN ' + QUOTENAME(@Db) + N'.sys.tables AS t
                  ON t.object_id = c.object_id
          INNER JOIN ' + QUOTENAME(@Db) + N'.sys.schemas AS s
                  ON s.schema_id = t.schema_id
          WHERE t.is_ms_shipped = 0
            AND EXISTS
            (
                SELECT 1
                FROM #SensitivePattern AS p
                WHERE LOWER(c.name) COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS
            );';

    BEGIN TRY
        INSERT INTO #SensitiveColumns (DatabaseName, SchemaName, TableName, ColumnName, IsMasked)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* Database unreachable, offline or insufficient permission - skipped */
    END CATCH

    FETCH NEXT FROM db_cursor INTO @Db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---- Evaluate ------------------------------------------------------------- */
DECLARE @NonProdCount   INT = (SELECT COUNT(*) FROM #NonProdDatabases);
DECLARE @SensitiveCount INT = (SELECT COUNT(*) FROM #SensitiveColumns);
DECLARE @MaskedCount    INT = (SELECT COUNT(*) FROM #SensitiveColumns WHERE IsMasked = 1);
DECLARE @UnmaskedCount  INT = (SELECT COUNT(*) FROM #SensitiveColumns WHERE IsMasked = 0);

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #NonProdDatabases AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Samples NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) N', ' + x.DatabaseName + N'.' + x.SchemaName + N'.' + x.TableName + N'.' + x.ColumnName
           FROM #SensitiveColumns AS x
           WHERE x.IsMasked = 0
           ORDER BY x.DatabaseName, x.SchemaName, x.TableName, x.ColumnName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result  NVARCHAR(50);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @NonProdCount = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No non-production database could be identified on this instance using standard naming conventions (dev, test, tst, qa, uat, stag, sandbox, demo, train, preprod, nonprod, poc). Masking/subsetting of non-production data cannot be verified from this server; confirm the environment classification and audit the actual non-production instances.';
END
ELSE IF @DdmSupported = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'Identified ' + CAST(@NonProdCount AS NVARCHAR(10)) + N' non-production database(s) (' + ISNULL(@DbList, N'n/a')
                 + N'), but this engine (major version ' + ISNULL(CAST(@MajorVersion AS NVARCHAR(10)), N'unknown')
                 + N') predates Dynamic Data Masking (SQL Server 2016), so applied masking state cannot be read from catalog metadata. Verify manually whether masking or subsetting is applied through ETL/refresh tooling.';
END
ELSE IF @SensitiveCount = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Identified ' + CAST(@NonProdCount AS NVARCHAR(10)) + N' non-production database(s) (' + ISNULL(@DbList, N'n/a')
                 + N'). No user-table columns matching sensitive data name patterns were found, so no unmasked sensitive data is exposed in these non-production databases.';
END
ELSE IF @UnmaskedCount = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CAST(@SensitiveCount AS NVARCHAR(10)) + N' sensitive-named column(s) across ' + CAST(@NonProdCount AS NVARCHAR(10))
                 + N' non-production database(s) (' + ISNULL(@DbList, N'n/a') + N') have Dynamic Data Masking applied.';
END
ELSE IF @MaskedCount > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Of ' + CAST(@SensitiveCount AS NVARCHAR(10)) + N' sensitive-named column(s) in ' + CAST(@NonProdCount AS NVARCHAR(10))
                 + N' non-production database(s) (' + ISNULL(@DbList, N'n/a') + N'), only ' + CAST(@MaskedCount AS NVARCHAR(10))
                 + N' are masked and ' + CAST(@UnmaskedCount AS NVARCHAR(10)) + N' remain unmasked. Examples: ' + ISNULL(@Samples, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score  = 1;
    SET @Finding = N'None of the ' + CAST(@SensitiveCount AS NVARCHAR(10)) + N' sensitive-named column(s) in ' + CAST(@NonProdCount AS NVARCHAR(10))
                 + N' non-production database(s) (' + ISNULL(@DbList, N'n/a') + N') have Dynamic Data Masking applied. Examples: '
                 + ISNULL(@Samples, N'n/a') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #SensitiveColumns;
DROP TABLE #NonProdDatabases;
DROP TABLE #SensitivePattern;
DROP TABLE #NonProdPattern;

SELECT
    @Result                 AS Result,
    @Score                  AS Score,
    ISNULL(@DbList, N'N/A') AS DatabaseQueried,
    @Finding                AS Finding;