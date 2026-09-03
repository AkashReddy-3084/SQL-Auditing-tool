SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;
IF OBJECT_ID('tempdb..#LooseType') IS NOT NULL DROP TABLE #LooseType;
IF OBJECT_ID('tempdb..#ModType') IS NOT NULL DROP TABLE #ModType;
IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Tbl') IS NOT NULL DROP TABLE #Tbl;
IF OBJECT_ID('tempdb..#Val') IS NOT NULL DROP TABLE #Val;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;

CREATE TABLE #Pat (Pattern nvarchar(100) NOT NULL, Kind tinyint NOT NULL);
CREATE TABLE #LooseType (TypeName sysname NOT NULL, RuleId tinyint NOT NULL);
CREATE TABLE #ModType (TypeCode char(2) NOT NULL);
CREATE TABLE #Db (DatabaseName sysname NOT NULL, Processed bit NOT NULL DEFAULT (0));
CREATE TABLE #Tbl (DatabaseName sysname NOT NULL, SchemaName sysname NOT NULL, TableName sysname NOT NULL,
                   TotalCols int NOT NULL, NotNullCols int NOT NULL, LooseCols int NOT NULL, ConstraintCount int NOT NULL);
CREATE TABLE #Val (DatabaseName sysname NOT NULL, ValidationObjects int NOT NULL);
CREATE TABLE #Skipped (DatabaseName sysname NOT NULL, ErrorText nvarchar(2000) NULL);

-- Kind 1 = inbound/staging object naming, Kind 2 = schema/data-validation routine naming
INSERT INTO #Pat (Pattern, Kind) VALUES
    (N'%stag%', 1), (N'%stg%', 1), (N'%landing%', 1), (N'%raw%', 1), (N'%import%', 1),
    (N'%inbound%', 1), (N'%ingest%', 1), (N'%feed%', 1), (N'%extract%', 1), (N'%etl%', 1), (N'%bulk%', 1),
    (N'%valid%', 2), (N'%verify%', 2), (N'%schema[_]check%', 2), (N'%checkschema%', 2),
    (N'%dataquality%', 2), (N'%data[_]quality%', 2), (N'%dq[_]%', 2), (N'%[_]dq%', 2),
    (N'%conform%', 2), (N'%cleanse%', 2);

-- RuleId 1 = always loose, RuleId 3 = string type that is loose only when very wide
INSERT INTO #LooseType (TypeName, RuleId) VALUES
    (N'text', 1), (N'ntext', 1), (N'image', 1), (N'sql_variant', 1), (N'xml', 1),
    (N'char', 3), (N'varchar', 3), (N'nchar', 3), (N'nvarchar', 3);

INSERT INTO #ModType (TypeCode) VALUES ('P'), ('PC'), ('FN'), ('IF'), ('TF'), ('TR');

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF @IsAzureDb = 1
    INSERT INTO #Db (DatabaseName) SELECT DB_NAME();
ELSE
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_distributor = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db sysname, @prefix nvarchar(300), @sql nvarchar(max);
DECLARE @body nvarchar(max) = N'
INSERT INTO #Tbl (DatabaseName, SchemaName, TableName, TotalCols, NotNullCols, LooseCols, ConstraintCount)
SELECT @dbn, s.name, t.name,
       COUNT(c.column_id),
       SUM(CASE WHEN c.is_nullable = 0 THEN 1 ELSE 0 END),
       SUM(CASE WHEN lt1.TypeName IS NOT NULL
                      OR c.max_length = -1
                      OR (lt3.TypeName IS NOT NULL AND c.max_length >= 4000)
                THEN 1 ELSE 0 END),
       MAX(x.ConstraintCount)
FROM {P}sys.tables t
INNER JOIN {P}sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN {P}sys.columns c ON c.object_id = t.object_id AND c.is_computed = 0
INNER JOIN {P}sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN #LooseType lt1 ON lt1.RuleId = 1 AND lt1.TypeName = ty.name
LEFT JOIN #LooseType lt3 ON lt3.RuleId = 3 AND lt3.TypeName = ty.name
CROSS APPLY (SELECT (SELECT COUNT(*) FROM {P}sys.check_constraints cc WHERE cc.parent_object_id = t.object_id)
                  + (SELECT COUNT(*) FROM {P}sys.key_constraints kc WHERE kc.parent_object_id = t.object_id)
                  + (SELECT COUNT(*) FROM {P}sys.foreign_keys fk WHERE fk.parent_object_id = t.object_id) AS ConstraintCount) x
WHERE t.is_ms_shipped = 0
  AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = 1 AND (t.name LIKE p.Pattern OR s.name LIKE p.Pattern))
GROUP BY s.name, t.name;

INSERT INTO #Val (DatabaseName, ValidationObjects)
SELECT @dbn, COUNT(*)
FROM {P}sys.objects o
WHERE o.is_ms_shipped = 0
  AND EXISTS (SELECT 1 FROM #ModType m WHERE m.TypeCode = o.type)
  AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = 2 AND o.name LIKE p.Pattern);
';

WHILE EXISTS (SELECT 1 FROM #Db WHERE Processed = 0)
BEGIN
    SELECT TOP (1) @db = DatabaseName FROM #Db WHERE Processed = 0 ORDER BY DatabaseName;
    UPDATE #Db SET Processed = 1 WHERE DatabaseName = @db;

    SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;
    SET @sql = REPLACE(@body, N'{P}', @prefix);

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName, ErrorText) VALUES (@db, ERROR_MESSAGE());
    END CATCH
END

DECLARE @Result varchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding nvarchar(max);
DECLARE @DbCount int, @SkipCount int, @Inbound int, @Enforced int, @Loose int, @ValObjs int, @Pct int, @Weak nvarchar(max);

SELECT @DbCount = COUNT(*)
FROM #Db d
WHERE NOT EXISTS (SELECT 1 FROM #Skipped k WHERE k.DatabaseName = d.DatabaseName);

SELECT @SkipCount = COUNT(*) FROM #Skipped;

SELECT @Inbound = COUNT(*),
       @Enforced = ISNULL(SUM(CASE WHEN NotNullCols > 0 AND ConstraintCount > 0 AND LooseCols * 2 < TotalCols THEN 1 ELSE 0 END), 0),
       @Loose = ISNULL(SUM(CASE WHEN LooseCols * 2 >= TotalCols OR (NotNullCols = 0 AND ConstraintCount = 0) THEN 1 ELSE 0 END), 0)
FROM #Tbl;

SELECT @ValObjs = ISNULL(SUM(ValidationObjects), 0) FROM #Val;

SET @DbCount = ISNULL(@DbCount, 0);
SET @SkipCount = ISNULL(@SkipCount, 0);
SET @Inbound = ISNULL(@Inbound, 0);
SET @Enforced = ISNULL(@Enforced, 0);
SET @Loose = ISNULL(@Loose, 0);
SET @ValObjs = ISNULL(@ValObjs, 0);
SET @Pct = CASE WHEN @Inbound = 0 THEN 0 ELSE (@Enforced * 100) / @Inbound END;

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
    SET @Result = 'Fail';
END
ELSE
BEGIN
    SELECT @DatabaseQueried = STUFF((SELECT N', ' + d.DatabaseName
                                     FROM #Db d
                                     WHERE NOT EXISTS (SELECT 1 FROM #Skipped k WHERE k.DatabaseName = d.DatabaseName)
                                     ORDER BY d.DatabaseName
                                     FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SELECT @Weak = STUFF((SELECT N', ' + q.DatabaseName + N' (' + CAST(q.LooseTables AS varchar(10)) + N' of ' + CAST(q.InboundTables AS varchar(10)) + N')'
                          FROM (SELECT DatabaseName,
                                       COUNT(*) AS InboundTables,
                                       SUM(CASE WHEN LooseCols * 2 >= TotalCols OR (NotNullCols = 0 AND ConstraintCount = 0) THEN 1 ELSE 0 END) AS LooseTables
                                FROM #Tbl
                                GROUP BY DatabaseName) q
                          WHERE q.LooseTables > 0
                          ORDER BY q.LooseTables DESC, q.DatabaseName
                          FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'None');

    SET @Score = CASE
                    WHEN @Inbound = 0 AND @ValObjs = 0 THEN 0
                    WHEN @Inbound = 0 THEN 2
                    WHEN @Pct >= 80 AND @ValObjs > 0 THEN 3
                    WHEN @Pct >= 50 THEN 2
                    ELSE 1
                 END;

    SET @Result = CASE WHEN @Score = 3 THEN 'Pass' WHEN @Score = 2 THEN 'NeedsReview' ELSE 'Fail' END;

    SET @Finding = CASE
                      WHEN @Inbound = 0 AND @ValObjs = 0
                        THEN N'Across ' + CAST(@DbCount AS varchar(10)) + N' database(s) no inbound/staging tables and no schema or data-quality validation routines were found; there is no in-database evidence that inbound data is checked for column presence or data types.'
                      WHEN @Inbound = 0
                        THEN N'Across ' + CAST(@DbCount AS varchar(10)) + N' database(s) no inbound/staging tables were identified, but ' + CAST(@ValObjs AS varchar(10)) + N' schema/data-validation routine(s) exist; validation coverage of the actual intake path cannot be confirmed from metadata alone.'
                      ELSE N'Across ' + CAST(@DbCount AS varchar(10)) + N' database(s): ' + CAST(@Inbound AS varchar(10))
                           + N' inbound/staging table(s) detected, ' + CAST(@Enforced AS varchar(10)) + N' (' + CAST(@Pct AS varchar(10))
                           + N'%) strongly typed with NOT NULL/CHECK/key enforcement, ' + CAST(@Loose AS varchar(10))
                           + N' loosely typed or unconstrained, and ' + CAST(@ValObjs AS varchar(10)) + N' schema/data-validation routine(s) present.'
                           + ISNULL(N' Weakest databases (loose of inbound tables): ' + @Weak + N'.', N'')
                   END
                   + CASE WHEN @SkipCount > 0 THEN N' ' + CAST(@SkipCount AS varchar(10)) + N' database(s) could not be inspected and were excluded.' ELSE N'' END;
END

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;

DROP TABLE #Pat;
DROP TABLE #LooseType;
DROP TABLE #ModType;
DROP TABLE #Db;
DROP TABLE #Tbl;
DROP TABLE #Val;
DROP TABLE #Skipped;