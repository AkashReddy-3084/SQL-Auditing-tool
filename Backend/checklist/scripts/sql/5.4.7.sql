SET NOCOUNT ON;

DECLARE @Result varchar(10) = 'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding nvarchar(max) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#FlagCols') IS NOT NULL DROP TABLE #FlagCols;
IF OBJECT_ID('tempdb..#DbSummary') IS NOT NULL DROP TABLE #DbSummary;
IF OBJECT_ID('tempdb..#BadValues') IS NOT NULL DROP TABLE #BadValues;

CREATE TABLE #DbList
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #FlagCols
(
    DatabaseName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    ColumnName sysname NOT NULL,
    TypeName sysname NOT NULL,
    MaxLength int NULL,
    IsBit bit NOT NULL,
    Representation nvarchar(40) NOT NULL,
    DistinctValueCount int NULL,
    SampleValues nvarchar(400) NULL,
    HasInvalidValue bit NOT NULL DEFAULT(0)
);

CREATE TABLE #DbSummary
(
    DatabaseName sysname NOT NULL PRIMARY KEY,
    FlagColCount int NOT NULL,
    BitColCount int NOT NULL,
    NonBitFlagCount int NOT NULL,
    InvalidValueCount int NOT NULL,
    RepresentationStyles int NOT NULL
);

CREATE TABLE #BadValues
(
    DatabaseName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    ColumnName sysname NOT NULL,
    BadSample nvarchar(400) NULL
);

DECLARE @IsAzure bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF @IsAzure = 1
BEGIN
    INSERT INTO #DbList (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.state = 0
      AND d.name NOT IN (N'master', N'tempdb', N'model', N'msdb')
      AND HAS_DBACCESS(d.name) = 1;
END;

DECLARE @Sql nvarchar(max);
DECLARE @Db sysname;
DECLARE @Schema sysname;
DECLARE @Table sysname;
DECLARE @Column sysname;
DECLARE @TypeName sysname;
DECLARE @MaxLength int;
DECLARE @cnt int;
DECLARE @samples nvarchar(400);
DECLARE @invalid bit;
DECLARE @tok nvarchar(400);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @IsAzure = 1
    BEGIN
        SET @Sql = N'
INSERT INTO #FlagCols
(
    DatabaseName, SchemaName, TableName, ColumnName, TypeName, MaxLength, IsBit, Representation
)
SELECT
    DB_NAME(),
    s.name,
    t.name,
    c.name,
    ty.name,
    c.max_length,
    CASE WHEN ty.name = N''bit'' THEN 1 ELSE 0 END,
    CASE
        WHEN ty.name = N''bit'' THEN N''bit''
        WHEN ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'') THEN N''integer_0_1''
        WHEN ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'') AND c.max_length IN (1, 2)
            THEN N''char_YN''
        WHEN ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'')
            THEN N''string_truefalse''
        ELSE N''other''
    END
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN sys.columns c ON c.object_id = t.object_id
INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND
  (
        ty.name = N''bit''
     OR c.name LIKE N''Is%''
     OR c.name LIKE N''Has%''
     OR c.name LIKE N''Can%''
     OR c.name LIKE N''Allow%''
     OR c.name LIKE N''Enable%''
     OR c.name LIKE N''Enabled%''
     OR c.name LIKE N''Active%''
     OR c.name LIKE N''Flag%''
     OR c.name LIKE N''%Flag''
     OR c.name LIKE N''%Ind''
     OR c.name LIKE N''%_Flg''
     OR c.name LIKE N''%_Flag''
     OR c.name LIKE N''Yn%''
     OR c.name LIKE N''%_YN''
     OR c.name LIKE N''%Yn''
  );';
    END
    ELSE
    BEGIN
        SET @Sql = N'
INSERT INTO #FlagCols
(
    DatabaseName, SchemaName, TableName, ColumnName, TypeName, MaxLength, IsBit, Representation
)
SELECT
    @DbName,
    s.name,
    t.name,
    c.name,
    ty.name,
    c.max_length,
    CASE WHEN ty.name = N''bit'' THEN 1 ELSE 0 END,
    CASE
        WHEN ty.name = N''bit'' THEN N''bit''
        WHEN ty.name IN (N''tinyint'', N''smallint'', N''int'', N''bigint'') THEN N''integer_0_1''
        WHEN ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'') AND c.max_length IN (1, 2)
            THEN N''char_YN''
        WHEN ty.name IN (N''char'', N''nchar'', N''varchar'', N''nvarchar'')
            THEN N''string_truefalse''
        ELSE N''other''
    END
FROM ' + QUOTENAME(@Db) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.columns c ON c.object_id = t.object_id
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND
  (
        ty.name = N''bit''
     OR c.name LIKE N''Is%''
     OR c.name LIKE N''Has%''
     OR c.name LIKE N''Can%''
     OR c.name LIKE N''Allow%''
     OR c.name LIKE N''Enable%''
     OR c.name LIKE N''Enabled%''
     OR c.name LIKE N''Active%''
     OR c.name LIKE N''Flag%''
     OR c.name LIKE N''%Flag''
     OR c.name LIKE N''%Ind''
     OR c.name LIKE N''%_Flg''
     OR c.name LIKE N''%_Flag''
     OR c.name LIKE N''Yn%''
     OR c.name LIKE N''%_YN''
     OR c.name LIKE N''%Yn''
  );';
    END;

    BEGIN TRY
        IF @IsAzure = 1
            EXEC sys.sp_executesql @Sql;
        ELSE
            EXEC sys.sp_executesql @Sql, N'@DbName sysname', @DbName = @Db;
    END TRY
    BEGIN CATCH
        -- Skip databases that cannot be fully read
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @Db;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, SchemaName, TableName, ColumnName, TypeName, MaxLength
    FROM #FlagCols
    WHERE IsBit = 0
    ORDER BY DatabaseName, SchemaName, TableName, ColumnName;

OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @Db, @Schema, @Table, @Column, @TypeName, @MaxLength;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cnt = NULL;
    SET @samples = NULL;
    SET @invalid = 0;

    IF @IsAzure = 1
    BEGIN
        SET @Sql = N'
SELECT
    @cntOut = COUNT(*),
    @samplesOut = STUFF((
        SELECT TOP (8) N'','' + REPLACE(REPLACE(CONVERT(nvarchar(40), v.val), N'','', N'';''), N''|'', N''/'')
        FROM (
            SELECT DISTINCT TOP (8) CONVERT(nvarchar(40), ' + QUOTENAME(@Column) + N') AS val
            FROM ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table) + N'
            WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL
        ) v
        FOR XML PATH(N''''), TYPE
    ).value(N''text()[1]'', N''nvarchar(400)''), 1, 1, N'''')
FROM (
    SELECT DISTINCT TOP (50) CONVERT(nvarchar(40), ' + QUOTENAME(@Column) + N') AS val
    FROM ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table) + N'
    WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL
) d;
';
    END
    ELSE
    BEGIN
        SET @Sql = N'
SELECT
    @cntOut = COUNT(*),
    @samplesOut = STUFF((
        SELECT TOP (8) N'','' + REPLACE(REPLACE(CONVERT(nvarchar(40), v.val), N'','', N'';''), N''|'', N''/'')
        FROM (
            SELECT DISTINCT TOP (8) CONVERT(nvarchar(40), ' + QUOTENAME(@Column) + N') AS val
            FROM ' + QUOTENAME(@Db) + N'.' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table) + N'
            WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL
        ) v
        FOR XML PATH(N''''), TYPE
    ).value(N''text()[1]'', N''nvarchar(400)''), 1, 1, N'''')
FROM (
    SELECT DISTINCT TOP (50) CONVERT(nvarchar(40), ' + QUOTENAME(@Column) + N') AS val
    FROM ' + QUOTENAME(@Db) + N'.' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table) + N'
    WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL
) d;
';
    END;

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@cntOut int OUTPUT, @samplesOut nvarchar(400) OUTPUT',
            @cntOut = @cnt OUTPUT,
            @samplesOut = @samples OUTPUT;

        UPDATE #FlagCols
        SET DistinctValueCount = ISNULL(@cnt, 0),
            SampleValues = @samples
        WHERE DatabaseName = @Db
          AND SchemaName = @Schema
          AND TableName = @Table
          AND ColumnName = @Column;

        IF @samples IS NOT NULL
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM #FlagCols f
                WHERE f.DatabaseName = @Db
                  AND f.SchemaName = @Schema
                  AND f.TableName = @Table
                  AND f.ColumnName = @Column
                  AND f.Representation = N'integer_0_1'
            )
            BEGIN
                IF @samples LIKE N'%2%' OR @samples LIKE N'%3%' OR @samples LIKE N'%4%'
                   OR @samples LIKE N'%5%' OR @samples LIKE N'%6%' OR @samples LIKE N'%7%'
                   OR @samples LIKE N'%8%' OR @samples LIKE N'%9%' OR @samples LIKE N'%-%'
                    SET @invalid = 1;
            END
            ELSE IF EXISTS (
                SELECT 1
                FROM #FlagCols f
                WHERE f.DatabaseName = @Db
                  AND f.SchemaName = @Schema
                  AND f.TableName = @Table
                  AND f.ColumnName = @Column
                  AND f.Representation = N'char_YN'
            )
            BEGIN
                IF @samples LIKE N'%[^YyNnTtFf01, ]%' COLLATE Latin1_General_BIN
                    SET @invalid = 1;
            END
            ELSE IF EXISTS (
                SELECT 1
                FROM #FlagCols f
                WHERE f.DatabaseName = @Db
                  AND f.SchemaName = @Schema
                  AND f.TableName = @Table
                  AND f.ColumnName = @Column
                  AND f.Representation = N'string_truefalse'
            )
            BEGIN
                SET @tok = LOWER(@samples);
                IF ISNULL(@cnt, 0) > 6
                    SET @invalid = 1;
                ELSE IF @tok NOT LIKE N'%true%'
                    AND @tok NOT LIKE N'%false%'
                    AND @tok NOT LIKE N'%yes%'
                    AND @tok NOT LIKE N'%no%'
                    AND @tok NOT LIKE N'%y%'
                    AND @tok NOT LIKE N'%n%'
                    AND @tok NOT LIKE N'%0%'
                    AND @tok NOT LIKE N'%1%'
                    AND LEN(@tok) > 0
                    SET @invalid = 1;
            END
            ELSE
            BEGIN
                IF ISNULL(@cnt, 0) > 4
                    SET @invalid = 1;
            END;
        END;

        IF @invalid = 1
        BEGIN
            UPDATE #FlagCols
            SET HasInvalidValue = 1
            WHERE DatabaseName = @Db
              AND SchemaName = @Schema
              AND TableName = @Table
              AND ColumnName = @Column;

            INSERT INTO #BadValues (DatabaseName, SchemaName, TableName, ColumnName, BadSample)
            VALUES (@Db, @Schema, @Table, @Column, @samples);
        END;
    END TRY
    BEGIN CATCH
        -- Skip unreadable tables/columns
    END CATCH;

    FETCH NEXT FROM col_cursor INTO @Db, @Schema, @Table, @Column, @TypeName, @MaxLength;
END;

CLOSE col_cursor;
DEALLOCATE col_cursor;

INSERT INTO #DbSummary
(
    DatabaseName, FlagColCount, BitColCount, NonBitFlagCount, InvalidValueCount, RepresentationStyles
)
SELECT
    f.DatabaseName,
    COUNT(*),
    SUM(CASE WHEN f.IsBit = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.IsBit = 0 THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.HasInvalidValue = 1 THEN 1 ELSE 0 END),
    COUNT(DISTINCT f.Representation)
FROM #FlagCols f
GROUP BY f.DatabaseName;

DECLARE @DbCount int = (SELECT COUNT(*) FROM #DbList);
DECLARE @FlagDbCount int = (SELECT COUNT(*) FROM #DbSummary);
DECLARE @TotalFlags int = (SELECT ISNULL(SUM(FlagColCount), 0) FROM #DbSummary);
DECLARE @TotalBit int = (SELECT ISNULL(SUM(BitColCount), 0) FROM #DbSummary);
DECLARE @TotalNonBit int = (SELECT ISNULL(SUM(NonBitFlagCount), 0) FROM #DbSummary);
DECLARE @TotalInvalid int = (SELECT ISNULL(SUM(InvalidValueCount), 0) FROM #DbSummary);
DECLARE @MaxStyles int = (SELECT ISNULL(MAX(RepresentationStyles), 0) FROM #DbSummary);
DECLARE @DbsMultiStyle int = (SELECT COUNT(*) FROM #DbSummary WHERE RepresentationStyles > 1);
DECLARE @NonBitPct decimal(9, 2) =
    CASE WHEN @TotalFlags = 0 THEN CAST(0 AS decimal(9, 2))
         ELSE CAST(@TotalNonBit AS decimal(9, 2)) * 100.0 / CAST(@TotalFlags AS decimal(9, 2))
    END;

DECLARE @BadPreview nvarchar(max);
SELECT @BadPreview = STUFF((
    SELECT TOP (5)
        N'; '
        + bv.DatabaseName + N'.' + bv.SchemaName + N'.' + bv.TableName
        + N'.' + bv.ColumnName + N'=[' + ISNULL(bv.BadSample, N'') + N']'
    FROM #BadValues bv
    ORDER BY bv.DatabaseName, bv.SchemaName, bv.TableName, bv.ColumnName
    FOR XML PATH(N''), TYPE
).value(N'text()[1]', N'nvarchar(max)'), 1, 2, N'');

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE IF @TotalFlags = 0
BEGIN
    SET @Score = 0;
    SELECT @DatabaseQueried = ISNULL(STUFF((
        SELECT N', ' + d.DatabaseName
        FROM #DbList d
        ORDER BY d.DatabaseName
        FOR XML PATH(N''), TYPE
    ).value(N'text()[1]', N'nvarchar(max)'), 1, 2, N''), N'None');
    SET @Finding = N'Queried ' + CAST(@DbCount AS varchar(20))
        + N' database(s); no bit columns or flag-named columns were found to evaluate.';
END
ELSE
BEGIN
    SELECT @DatabaseQueried = ISNULL(STUFF((
        SELECT N', ' + d.DatabaseName
        FROM #DbList d
        ORDER BY d.DatabaseName
        FOR XML PATH(N''), TYPE
    ).value(N'text()[1]', N'nvarchar(max)'), 1, 2, N''), N'None');

    IF @TotalInvalid > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Found ' + CAST(@TotalFlags AS varchar(20)) + N' flag-like column(s) across '
            + CAST(@FlagDbCount AS varchar(20)) + N' database(s); '
            + CAST(@TotalInvalid AS varchar(20))
            + N' non-bit flag column(s) have values outside expected boolean domains.'
            + CASE WHEN ISNULL(@BadPreview, N'') <> N'' THEN N' Examples: ' + @BadPreview + N'.' ELSE N'' END;
    END
    ELSE IF @TotalNonBit = 0 AND @MaxStyles <= 1
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@TotalFlags AS varchar(20)) + N' flag-like column(s) across '
            + CAST(@FlagDbCount AS varchar(20))
            + N' database(s) use bit type with a single consistent representation.';
    END
    ELSE IF @NonBitPct <= 10.00 AND @DbsMultiStyle = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Found ' + CAST(@TotalFlags AS varchar(20)) + N' flag-like column(s) ('
            + CAST(@TotalBit AS varchar(20)) + N' bit, ' + CAST(@TotalNonBit AS varchar(20))
            + N' non-bit). Non-bit usage is limited ('
            + CAST(@NonBitPct AS varchar(20))
            + N'%) with no invalid values and consistent representation per database.';
    END
    ELSE IF @NonBitPct <= 35.00 AND @DbsMultiStyle <= 2
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Found ' + CAST(@TotalFlags AS varchar(20)) + N' flag-like column(s) across '
            + CAST(@FlagDbCount AS varchar(20)) + N' database(s): '
            + CAST(@TotalBit AS varchar(20)) + N' bit and ' + CAST(@TotalNonBit AS varchar(20))
            + N' non-bit. Minor representation variance without invalid values.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Found ' + CAST(@TotalFlags AS varchar(20)) + N' flag-like column(s): '
            + CAST(@TotalBit AS varchar(20)) + N' bit, ' + CAST(@TotalNonBit AS varchar(20))
            + N' non-bit (' + CAST(@NonBitPct AS varchar(20)) + N'%). '
            + CAST(@DbsMultiStyle AS varchar(20))
            + N' database(s) mix multiple flag representations (bit/int/char/string), reducing consistency.';
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;