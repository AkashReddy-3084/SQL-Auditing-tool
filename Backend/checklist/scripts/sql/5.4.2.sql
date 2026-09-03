SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#NumericFindings') IS NOT NULL DROP TABLE #NumericFindings;
CREATE TABLE #NumericFindings (
    DatabaseName   sysname       NOT NULL,
    SchemaName     sysname       NOT NULL,
    TableName      sysname       NOT NULL,
    ColumnName     sysname       NOT NULL,
    TypeName       sysname       NOT NULL,
    PrecisionVal   int           NULL,
    ScaleVal       int           NULL,
    MaxLength      int           NULL,
    IssueCategory  varchar(40)   NOT NULL,
    IssueDetail    varchar(300)  NOT NULL,
    Severity       tinyint       NOT NULL
);

IF OBJECT_ID('tempdb..#TargetDbs') IS NOT NULL DROP TABLE #TargetDbs;
CREATE TABLE #TargetDbs (
    DatabaseName sysname NOT NULL PRIMARY KEY
);

INSERT INTO #TargetDbs (DatabaseName)
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = N'ONLINE'
  AND HAS_DBACCESS(name) = 1
  AND ISNULL(CONVERT(sysname, DATABASEPROPERTYEX(name, 'Updateability')), N'') IN (N'READ_WRITE', N'READ_ONLY');

DECLARE @Score int;
DECLARE @Result varchar(10);
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM #TargetDbs)
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END
ELSE
BEGIN
    DECLARE @sql nvarchar(max) = N'
USE [?];
IF DB_ID() IS NULL RETURN;
IF DATABASEPROPERTYEX(DB_NAME(), ''Status'') <> ''ONLINE'' RETURN;
IF DATABASEPROPERTYEX(DB_NAME(), ''Updateability'') <> ''READ_WRITE''
   AND DATABASEPROPERTYEX(DB_NAME(), ''Updateability'') <> ''READ_ONLY'' RETURN;

INSERT INTO #NumericFindings (
    DatabaseName, SchemaName, TableName, ColumnName, TypeName,
    PrecisionVal, ScaleVal, MaxLength, IssueCategory, IssueDetail, Severity
)
SELECT
    x.DatabaseName,
    x.SchemaName,
    x.TableName,
    x.ColumnName,
    x.TypeName,
    x.PrecisionVal,
    x.ScaleVal,
    x.MaxLength,
    x.IssueCategory,
    x.IssueDetail,
    x.Severity
FROM (
    SELECT
        DB_NAME() AS DatabaseName,
        s.name AS SchemaName,
        t.name AS TableName,
        c.name AS ColumnName,
        ty.name AS TypeName,
        c.precision AS PrecisionVal,
        c.scale AS ScaleVal,
        c.max_length AS MaxLength,
        CASE
            WHEN ty.name IN (N''float'', N''real'')
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%salary%'' OR c.name LIKE N''%wage%''
                     OR c.name LIKE N''%revenue%'' OR c.name LIKE N''%income%'' OR c.name LIKE N''%expense%''
                     OR c.name LIKE N''%currency%amt%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%debit%''
                     OR c.name LIKE N''%credit%'' OR c.name LIKE N''%invoice%'' OR c.name LIKE N''%total%''
                     OR c.name LIKE N''%rate%'' OR c.name LIKE N''%pct%'' OR c.name LIKE N''%percent%''
                     OR c.name LIKE N''%discount%'' OR c.name LIKE N''%interest%'' OR c.name LIKE N''%principal%''
                 )
                THEN N''FloatRealFinancial''
            WHEN ty.name IN (N''money'', N''smallmoney'')
                THEN N''MoneyType''
            WHEN ty.name IN (N''decimal'', N''numeric'') AND c.scale = 0
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%total%''
                 )
                THEN N''DecimalZeroScaleFinancial''
            WHEN (
                     c.name LIKE N''%currency%code%'' OR c.name LIKE N''%curr%code%''
                     OR c.name = N''Currency'' OR c.name = N''CurrencyCode'' OR c.name = N''CurrCode''
                     OR c.name = N''ISOCurrency'' OR c.name LIKE N''%_ccy'' OR c.name LIKE N''%CcyCode%''
                 )
                 AND ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'')
                 AND (
                     (ty.name IN (N''char'', N''nchar'') AND c.max_length NOT IN (3, 6))
                     OR (ty.name = N''varchar'' AND c.max_length <> -1 AND (c.max_length < 3 OR c.max_length > 3))
                     OR (ty.name = N''nvarchar'' AND c.max_length <> -1 AND (c.max_length < 6 OR c.max_length > 6))
                 )
                THEN N''CurrencyCodeDefinition''
            ELSE NULL
        END AS IssueCategory,
        CASE
            WHEN ty.name IN (N''float'', N''real'')
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%salary%'' OR c.name LIKE N''%wage%''
                     OR c.name LIKE N''%revenue%'' OR c.name LIKE N''%income%'' OR c.name LIKE N''%expense%''
                     OR c.name LIKE N''%currency%amt%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%debit%''
                     OR c.name LIKE N''%credit%'' OR c.name LIKE N''%invoice%'' OR c.name LIKE N''%total%''
                     OR c.name LIKE N''%rate%'' OR c.name LIKE N''%pct%'' OR c.name LIKE N''%percent%''
                     OR c.name LIKE N''%discount%'' OR c.name LIKE N''%interest%'' OR c.name LIKE N''%principal%''
                 )
                THEN N''Approximate type '' + ty.name + N'' used for financial-like column; binary floating point can introduce rounding errors.''
            WHEN ty.name IN (N''money'', N''smallmoney'')
                THEN N''Type '' + ty.name + N'' is fixed-scale legacy money; prefer decimal/numeric with explicit precision/scale for financial amounts.''
            WHEN ty.name IN (N''decimal'', N''numeric'') AND c.scale = 0
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%total%''
                 )
                THEN N''Financial-like decimal/numeric has scale 0 (no fractional precision); may cause rounding/truncation of currency amounts.''
            WHEN (
                     c.name LIKE N''%currency%code%'' OR c.name LIKE N''%curr%code%''
                     OR c.name = N''Currency'' OR c.name = N''CurrencyCode'' OR c.name = N''CurrCode''
                     OR c.name = N''ISOCurrency'' OR c.name LIKE N''%_ccy'' OR c.name LIKE N''%CcyCode%''
                 )
                 AND ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'')
                THEN N''Currency-code column definition may not match ISO 4217 (expected 3 characters); type=''
                     + ty.name + N'', max_length='' + CONVERT(varchar(11), c.max_length) + N''.''
            ELSE NULL
        END AS IssueDetail,
        CASE
            WHEN ty.name IN (N''float'', N''real'')
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%salary%'' OR c.name LIKE N''%wage%''
                     OR c.name LIKE N''%revenue%'' OR c.name LIKE N''%income%'' OR c.name LIKE N''%expense%''
                     OR c.name LIKE N''%currency%amt%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%debit%''
                     OR c.name LIKE N''%credit%'' OR c.name LIKE N''%invoice%'' OR c.name LIKE N''%total%''
                     OR c.name LIKE N''%rate%'' OR c.name LIKE N''%pct%'' OR c.name LIKE N''%percent%''
                     OR c.name LIKE N''%discount%'' OR c.name LIKE N''%interest%'' OR c.name LIKE N''%principal%''
                 )
                THEN CONVERT(tinyint, 1)
            WHEN (
                     c.name LIKE N''%currency%code%'' OR c.name LIKE N''%curr%code%''
                     OR c.name = N''Currency'' OR c.name = N''CurrencyCode'' OR c.name = N''CurrCode''
                     OR c.name = N''ISOCurrency'' OR c.name LIKE N''%_ccy'' OR c.name LIKE N''%CcyCode%''
                 )
                 AND ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'')
                 AND (
                     (ty.name IN (N''char'', N''nchar'') AND c.max_length NOT IN (3, 6))
                     OR (ty.name = N''varchar'' AND c.max_length <> -1 AND (c.max_length < 3 OR c.max_length > 3))
                     OR (ty.name = N''nvarchar'' AND c.max_length <> -1 AND (c.max_length < 6 OR c.max_length > 6))
                 )
                THEN CONVERT(tinyint, 1)
            WHEN ty.name IN (N''money'', N''smallmoney'')
                THEN CONVERT(tinyint, 2)
            WHEN ty.name IN (N''decimal'', N''numeric'') AND c.scale = 0
                 AND (
                     c.name LIKE N''%amount%'' OR c.name LIKE N''%price%'' OR c.name LIKE N''%cost%''
                     OR c.name LIKE N''%fee%'' OR c.name LIKE N''%tax%'' OR c.name LIKE N''%balance%''
                     OR c.name LIKE N''%payment%'' OR c.name LIKE N''%money%'' OR c.name LIKE N''%total%''
                 )
                THEN CONVERT(tinyint, 2)
            ELSE NULL
        END AS Severity
    FROM sys.tables t
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    INNER JOIN sys.columns c ON c.object_id = t.object_id
    INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
      AND OBJECTPROPERTY(t.object_id, ''IsMSShipped'') = 0
) AS x
WHERE x.IssueCategory IS NOT NULL
  AND x.IssueDetail IS NOT NULL
  AND x.Severity IS NOT NULL;
';

    DECLARE @db sysname;
    DECLARE @stmt nvarchar(max);
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM #TargetDbs ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @stmt = REPLACE(@sql, N'?', REPLACE(@db, N']', N']]'));
        BEGIN TRY
            EXEC sys.sp_executesql @stmt;
        END TRY
        BEGIN CATCH
            -- Skip databases that cannot be queried
        END CATCH
        FETCH NEXT FROM db_cursor INTO @db;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    DECLARE @high int = (SELECT COUNT(*) FROM #NumericFindings WHERE Severity = 1);
    DECLARE @med int = (SELECT COUNT(*) FROM #NumericFindings WHERE Severity = 2);
    DECLARE @total int = (SELECT COUNT(*) FROM #NumericFindings);

    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + DatabaseName
        FROM #TargetDbs
        ORDER BY DatabaseName
        FOR XML PATH(N''), TYPE
    ).value(N'.', N'nvarchar(max)'), 1, 2, N'');

    DECLARE @sample nvarchar(max);
    SELECT @sample = STUFF((
        SELECT TOP 15
            N'; ' + DatabaseName + N'.' + SchemaName + N'.' + TableName + N'.' + ColumnName
            + N' [' + IssueCategory + N': ' + TypeName + N']'
        FROM #NumericFindings
        ORDER BY Severity ASC, DatabaseName, SchemaName, TableName, ColumnName
        FOR XML PATH(N''), TYPE
    ).value(N'.', N'nvarchar(max)'), 1, 2, N'');

    IF @high = 0 AND @med = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No numeric/financial precision or currency-code definition issues detected across accessible user databases. Catalog scan found no float/real financial-like columns, no zero-scale financial decimals of concern, and no currency-code column length mismatches.';
    END
    ELSE IF @high = 0 AND @med > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Found ' + CONVERT(varchar(11), @med)
            + N' medium-severity numeric/financial definition issue(s) (money/smallmoney and/or scale-0 financial decimals) and 0 high-severity float/real or currency-code issues. Sample: '
            + ISNULL(@sample, N'n/a');
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Found ' + CONVERT(varchar(11), @high)
            + N' high-severity issue(s) (float/real on financial-like columns and/or invalid currency-code definitions) and '
            + CONVERT(varchar(11), @med) + N' medium-severity issue(s). Total findings: '
            + CONVERT(varchar(11), @total) + N'. Sample: ' + ISNULL(@sample, N'n/a');
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    IF LEN(@Finding) > 3500
        SET @Finding = LEFT(@Finding, 3497) + N'...';

    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END

DROP TABLE #NumericFindings;
DROP TABLE #TargetDbs;