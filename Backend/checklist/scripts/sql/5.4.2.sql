/*
    Checklist 5.4.2 - Numeric / Financial: precision preserved; no rounding errors; currency codes valid
    Read-only metadata inspection of every accessible user database. No data is modified.
*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList
(
    DatabaseName sysname NOT NULL PRIMARY KEY,
    Scanned      bit     NOT NULL DEFAULT (0)
);

IF OBJECT_ID('tempdb..#Cols') IS NOT NULL DROP TABLE #Cols;
CREATE TABLE #Cols
(
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    TableName       sysname       NOT NULL,
    ColumnName      sysname       NOT NULL,
    DataTypeName    nvarchar(128) NOT NULL,
    NumScale        int           NULL,
    CharLen         int           NULL,
    IsMonetaryName  bit           NOT NULL,
    IsCurrencyName  bit           NOT NULL,
    HasValueControl bit           NOT NULL
);

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings
(
    DatabaseName sysname       NOT NULL,
    SchemaName   sysname       NOT NULL,
    TableName    sysname       NOT NULL,
    ColumnName   sysname       NOT NULL,
    DataTypeName nvarchar(128) NOT NULL,
    IssueType    varchar(40)   NOT NULL
);

/* Azure SQL Database cannot enumerate sibling databases - inspect the current one only. */
IF @IsAzureSqlDb = 1
    INSERT INTO #DbList (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.name NOT IN ('SSISDB', 'distribution', 'ReportServer', 'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db sysname, @sql nvarchar(max), @FailedDbs int = 0;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
INSERT INTO #Cols (DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, NumScale, CharLen, IsMonetaryName, IsCurrencyName, HasValueControl)
SELECT @dbn, x.SchemaName, x.TableName, x.ColumnName, x.DataTypeName, x.NumScale, x.CharLen, x.IsMonetaryName, x.IsCurrencyName, x.HasValueControl
FROM (
    SELECT s.name AS SchemaName,
           t.name AS TableName,
           c.name AS ColumnName,
           ty.name AS DataTypeName,
           c.scale AS NumScale,
           CASE WHEN ty.name IN (N''nchar'', N''nvarchar'') AND c.max_length > 0
                THEN c.max_length / 2 ELSE c.max_length END AS CharLen,
           CASE WHEN LOWER(c.name) LIKE N''%amount%''  OR LOWER(c.name) LIKE N''%amt%''
                  OR LOWER(c.name) LIKE N''%price%''   OR LOWER(c.name) LIKE N''%cost%''
                  OR LOWER(c.name) LIKE N''%salary%''  OR LOWER(c.name) LIKE N''%wage%''
                  OR LOWER(c.name) LIKE N''%balance%'' OR LOWER(c.name) LIKE N''%revenue%''
                  OR LOWER(c.name) LIKE N''%payment%'' OR LOWER(c.name) LIKE N''%fee%''
                  OR LOWER(c.name) LIKE N''%charge%''  OR LOWER(c.name) LIKE N''%discount%''
                  OR LOWER(c.name) LIKE N''%total%''   OR LOWER(c.name) LIKE N''%invoice%''
                  OR LOWER(c.name) LIKE N''%credit%''  OR LOWER(c.name) LIKE N''%debit%''
                  OR LOWER(c.name) LIKE N''%profit%''  OR LOWER(c.name) LIKE N''%budget%''
                THEN 1 ELSE 0 END AS IsMonetaryName,
           CASE WHEN LOWER(c.name) LIKE N''%currency%'' OR LOWER(c.name) LIKE N''%ccy%''
                THEN 1 ELSE 0 END AS IsCurrencyName,
           CASE WHEN EXISTS (SELECT 1
                             FROM ' + QUOTENAME(@db) + N'.sys.check_constraints AS cc
                             WHERE cc.parent_object_id = c.object_id
                               AND (cc.parent_column_id = c.column_id
                                    OR cc.definition LIKE N''%[[]'' + c.name + N'']%''))
                  OR EXISTS (SELECT 1
                             FROM ' + QUOTENAME(@db) + N'.sys.foreign_key_columns AS fkc
                             WHERE fkc.parent_object_id = c.object_id
                               AND fkc.parent_column_id = c.column_id)
                THEN 1 ELSE 0 END AS HasValueControl
    FROM ' + QUOTENAME(@db) + N'.sys.columns AS c
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.tables AS t ON t.object_id = c.object_id
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
) AS x
WHERE x.IsMonetaryName = 1
   OR x.IsCurrencyName = 1
   OR x.DataTypeName IN (N''money'', N''smallmoney'');';

        EXEC sys.sp_executesql @sql, N'@dbn sysname', @dbn = @db;

        UPDATE #DbList SET Scanned = 1 WHERE DatabaseName = @db;
    END TRY
    BEGIN CATCH
        SET @FailedDbs = @FailedDbs + 1;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* Classify the collected candidate columns. */
INSERT INTO #Findings (DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, IssueType)
SELECT DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, 'FloatMonetaryColumn'
FROM #Cols
WHERE IsMonetaryName = 1 AND DataTypeName IN ('float', 'real')
UNION ALL
SELECT DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, 'ZeroScaleDecimalMonetary'
FROM #Cols
WHERE IsMonetaryName = 1 AND DataTypeName IN ('decimal', 'numeric') AND NumScale = 0
UNION ALL
SELECT DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, 'LegacyMoneyType'
FROM #Cols
WHERE DataTypeName IN ('money', 'smallmoney')
UNION ALL
SELECT DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, 'UnconstrainedCurrencyCode'
FROM #Cols
WHERE IsCurrencyName = 1
  AND DataTypeName IN ('char', 'varchar', 'nchar', 'nvarchar')
  AND CharLen BETWEEN 1 AND 10
  AND HasValueControl = 0
UNION ALL
SELECT DatabaseName, SchemaName, TableName, ColumnName, DataTypeName, 'CurrencyCodeLengthNotIso'
FROM #Cols
WHERE IsCurrencyName = 1
  AND DataTypeName IN ('char', 'varchar', 'nchar', 'nvarchar')
  AND CharLen BETWEEN 1 AND 10
  AND CharLen <> 3;

DECLARE @DbScanned     int = (SELECT COUNT(*) FROM #DbList WHERE Scanned = 1),
        @DbTotal       int = (SELECT COUNT(*) FROM #DbList),
        @CandidateCols int = (SELECT COUNT(*) FROM #Cols),
        @MonetaryCols  int = (SELECT COUNT(*) FROM #Cols WHERE IsMonetaryName = 1 OR DataTypeName IN ('money', 'smallmoney')),
        @CurrencyCols  int = (SELECT COUNT(*) FROM #Cols WHERE IsCurrencyName = 1),
        @FloatMoney    int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'FloatMonetaryColumn'),
        @ZeroScale     int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'ZeroScaleDecimalMonetary'),
        @LegacyMoney   int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'LegacyMoneyType'),
        @UnconCurr     int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'UnconstrainedCurrencyCode'),
        @BadCurrLen    int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = 'CurrencyCodeLengthNotIso');

DECLARE @Critical int = @FloatMoney + @ZeroScale,
        @CurrencyIssues int = @UnconCurr + @BadCurrLen;

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #DbList AS d
                  WHERE d.Scanned = 1
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (10) N'; ' + f.DatabaseName + N'.' + f.SchemaName + N'.' + f.TableName + N'.' + f.ColumnName
                         + N' (' + f.DataTypeName + N' / ' + f.IssueType + N')'
                  FROM #Findings AS f
                  ORDER BY CASE f.IssueType
                               WHEN 'FloatMonetaryColumn' THEN 1
                               WHEN 'ZeroScaleDecimalMonetary' THEN 2
                               WHEN 'UnconstrainedCurrencyCode' THEN 3
                               WHEN 'CurrencyCodeLengthNotIso' THEN 4
                               ELSE 5
                           END,
                           f.DatabaseName, f.SchemaName, f.TableName, f.ColumnName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Counts nvarchar(max) =
    CONCAT(N'Databases inspected: ', @DbScanned, N' of ', @DbTotal,
           N' (inaccessible/errored: ', @FailedDbs, N'). Candidate columns: ', @CandidateCols,
           N' (monetary: ', @MonetaryCols, N', currency-code: ', @CurrencyCols,
           N'). float/real monetary columns: ', @FloatMoney,
           N'; scale-0 decimal monetary columns: ', @ZeroScale,
           N'; legacy money/smallmoney columns: ', @LegacyMoney,
           N'; currency-code columns with no CHECK/FK: ', @UnconCurr,
           N'; currency-code columns not 3 characters: ', @BadCurrLen, N'.');

DECLARE @Score int, @Result varchar(20), @Finding nvarchar(max);

IF @DbScanned = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT(N'No user database could be inspected, so numeric precision and currency-code validity could not be evidenced. ', @Counts);
END
ELSE IF @CandidateCols = 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT(N'No monetary or currency-code columns were detected in the inspected databases, so no precision-loss or invalid-currency-code exposure exists. ', @Counts);
END
ELSE IF @Critical = 0 AND @CurrencyIssues = 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT(N'All monetary columns use exact numeric types with a non-zero scale and every currency-code column is 3 characters and controlled by a CHECK constraint or foreign key. ', @Counts,
                          N' Advisory examples: ', @Examples);
END
ELSE IF @Critical = 0
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT(N'Monetary columns use precision-safe types, but ', @CurrencyIssues,
                          N' currency-code column(s) are unvalidated or not ISO 4217 (3 character) length. ', @Counts,
                          N' Examples: ', @Examples);
END
ELSE IF @Critical <= 5
BEGIN
    SET @Score = 1;
    SET @Finding = CONCAT(N'Precision defects found: ', @Critical,
                          N' monetary column(s) use approximate float/real types or a zero-scale decimal, plus ', @CurrencyIssues,
                          N' currency-code issue(s). ', @Counts, N' Examples: ', @Examples);
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT(N'Widespread precision defects: ', @Critical,
                          N' monetary column(s) use approximate float/real types or a zero-scale decimal, plus ', @CurrencyIssues,
                          N' currency-code issue(s). ', @Counts, N' Examples: ', @Examples);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Cols') IS NOT NULL DROP TABLE #Cols;
IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;