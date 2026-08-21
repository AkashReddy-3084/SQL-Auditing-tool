/* =====================================================================
   Checklist 5.4.1 - Dates: valid ranges; consistent handling;
                     no invalid future dates where prohibited
   Scope       : DATABASE (all accessible online user databases)
   Read-only   : catalog views + SELECT-only profiling. No DDL/DML on
                 user objects (temp tables only).
   ===================================================================== */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @Result          nvarchar(20),
        @Score           int,
        @DatabaseQueried nvarchar(max),
        @Finding         nvarchar(max),
        @Detail          nvarchar(max),
        @TypeDetail      nvarchar(max),
        @ErrorMessage    nvarchar(4000) = NULL;

DECLARE @DbCount         int = 0,
        @TotalDateCols   int = 0,
        @RangeCols       int = 0,
        @FutureCols      int = 0,
        @TypeCols        int = 0,
        @SkippedCols     int = 0;

DECLARE @RangeRows       bigint = 0,
        @FutureRows      bigint = 0;

IF OBJECT_ID('tempdb..#Databases')    IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#DateColumns')  IS NOT NULL DROP TABLE #DateColumns;
IF OBJECT_ID('tempdb..#DateFindings') IS NOT NULL DROP TABLE #DateFindings;

CREATE TABLE #Databases
(
    DbName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #DateColumns
(
    RowId       int IDENTITY(1,1) PRIMARY KEY,
    DbName      sysname NOT NULL,
    SchemaName  sysname NOT NULL,
    TableName   sysname NOT NULL,
    ColumnName  sysname NOT NULL,
    IsPastOnly  bit     NOT NULL          -- column name implies an event that cannot be in the future
);

CREATE TABLE #DateFindings
(
    DbName      sysname     NOT NULL,
    SchemaName  sysname     NOT NULL,
    TableName   sysname     NOT NULL,
    ColumnName  sysname     NOT NULL,
    IssueType   varchar(30) NOT NULL,
    BadRows     bigint      NULL
);

/* -------------------------------------------------------------------
   1. Qualifying user databases
   ------------------------------------------------------------------- */
INSERT INTO #Databases (DbName)
SELECT  d.name
FROM    sys.databases AS d
WHERE   d.database_id > 4
  AND   d.name <> 'distribution'
  AND   d.state_desc = 'ONLINE'
  AND   d.source_database_id IS NULL
  AND   d.is_in_standby = 0
  AND   HAS_DBACCESS(d.name) = 1;

SELECT @DbCount = COUNT(*) FROM #Databases;

IF @DbCount = 0
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
END
ELSE
BEGIN
    SELECT @DatabaseQueried = STUFF(
        ( SELECT N', ' + d.DbName
          FROM   #Databases AS d
          ORDER  BY d.DbName
          FOR XML PATH(''), TYPE ).value('.', 'nvarchar(max)'), 1, 2, N'');

    DECLARE @Db sysname, @sql nvarchar(max);

    /* ---------------------------------------------------------------
       2. Enumerate temporal columns and mistyped date-like columns
       --------------------------------------------------------------- */
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
        SELECT DbName FROM #Databases ORDER BY DbName;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @Db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql =
                N'SELECT ' + QUOTENAME(@Db, '''') + N', s.name, t.name, c.name, ' +
                N'       CASE WHEN c.name LIKE ''%creat%''  OR c.name LIKE ''%modif%''  OR c.name LIKE ''%updat%'' ' +
                N'              OR c.name LIKE ''%birth%''  OR c.name LIKE ''%dob''     OR c.name LIKE ''%hire%'' ' +
                N'              OR c.name LIKE ''%insert%'' OR c.name LIKE ''%receiv%'' OR c.name LIKE ''%post%'' ' +
                N'              OR c.name LIKE ''%load%''   THEN 1 ELSE 0 END ' +
                N'FROM ' + QUOTENAME(@Db) + N'.sys.columns AS c ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.tables  AS t  ON t.object_id     = c.object_id ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.schemas AS s  ON s.schema_id     = t.schema_id ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.types   AS ty ON ty.user_type_id = c.user_type_id ' +
                N'WHERE t.is_ms_shipped = 0 AND c.is_computed = 0 ' +
                N'  AND ty.name IN (''date'', ''datetime'', ''datetime2'', ''smalldatetime'', ''datetimeoffset'') ' +
                N'  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');';

            INSERT INTO #DateColumns (DbName, SchemaName, TableName, ColumnName, IsPastOnly)
            EXEC sp_executesql @sql;

            SET @sql =
                N'SELECT ' + QUOTENAME(@Db, '''') + N', s.name, t.name, c.name, ''NonDateStorageType'', NULL ' +
                N'FROM ' + QUOTENAME(@Db) + N'.sys.columns AS c ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.tables  AS t  ON t.object_id     = c.object_id ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.schemas AS s  ON s.schema_id     = t.schema_id ' +
                N'JOIN ' + QUOTENAME(@Db) + N'.sys.types   AS ty ON ty.user_type_id = c.user_type_id ' +
                N'WHERE t.is_ms_shipped = 0 AND c.is_computed = 0 ' +
                N'  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'') ' +
                N'  AND ty.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''int'', ''bigint'', ''numeric'', ''decimal'', ''float'', ''real'') ' +
                N'  AND ( c.name LIKE ''%[_]date%'' OR c.name LIKE ''date%''  OR c.name LIKE ''%date'' ' +
                N'     OR c.name LIKE ''%datetime%'' OR c.name LIKE ''%dttm%'' OR c.name LIKE ''%dob'' );';

            INSERT INTO #DateFindings (DbName, SchemaName, TableName, ColumnName, IssueType, BadRows)
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ISNULL(@ErrorMessage + N' | ', N'') + @Db + N': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cur INTO @Db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;

    SELECT @TotalDateCols = COUNT(*) FROM #DateColumns;

    /* ---------------------------------------------------------------
       3. Profile each temporal column (SELECT only)
       --------------------------------------------------------------- */
    DECLARE @Sch sysname, @Tab sysname, @Col sysname, @PastOnly bit;
    DECLARE @Rng bigint, @Fut bigint;
    DECLARE @FutureThreshold datetime2(0) = DATEADD(DAY, 1, CAST(SYSDATETIME() AS datetime2(0)));

    DECLARE col_cur CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
        SELECT DbName, SchemaName, TableName, ColumnName, IsPastOnly
        FROM   #DateColumns
        ORDER  BY RowId;

    OPEN col_cur;
    FETCH NEXT FROM col_cur INTO @Db, @Sch, @Tab, @Col, @PastOnly;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Rng = NULL;
        SET @Fut = NULL;

        BEGIN TRY
            /* CAST to datetime2 first so the range literals never overflow
               the narrower smalldatetime/date domains. */
            SET @sql =
                N'SELECT @rng = COUNT_BIG(CASE WHEN x.v < CONVERT(datetime2(0), ''1900-01-01'') ' +
                N'                              OR x.v >= CONVERT(datetime2(0), ''9999-01-01'') THEN 1 END), ' +
                N'       @fut = COUNT_BIG(CASE WHEN @pastOnly = 1 AND x.v > @futThreshold THEN 1 END) ' +
                N'FROM ( SELECT CAST(' + QUOTENAME(@Col) + N' AS datetime2(0)) AS v ' +
                N'       FROM ' + QUOTENAME(@Db) + N'.' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tab) + N' ) AS x ' +
                N'WHERE x.v IS NOT NULL;';

            EXEC sp_executesql
                 @sql,
                 N'@rng bigint OUTPUT, @fut bigint OUTPUT, @pastOnly bit, @futThreshold datetime2(0)',
                 @rng          = @Rng OUTPUT,
                 @fut          = @Fut OUTPUT,
                 @pastOnly     = @PastOnly,
                 @futThreshold = @FutureThreshold;

            IF ISNULL(@Rng, 0) > 0
                INSERT INTO #DateFindings (DbName, SchemaName, TableName, ColumnName, IssueType, BadRows)
                VALUES (@Db, @Sch, @Tab, @Col, 'InvalidDateRange', @Rng);

            IF ISNULL(@Fut, 0) > 0
                INSERT INTO #DateFindings (DbName, SchemaName, TableName, ColumnName, IssueType, BadRows)
                VALUES (@Db, @Sch, @Tab, @Col, 'ProhibitedFutureDate', @Fut);
        END TRY
        BEGIN CATCH
            SET @SkippedCols = @SkippedCols + 1;
        END CATCH

        FETCH NEXT FROM col_cur INTO @Db, @Sch, @Tab, @Col, @PastOnly;
    END

    CLOSE col_cur;
    DEALLOCATE col_cur;

    /* ---------------------------------------------------------------
       4. Aggregate
       --------------------------------------------------------------- */
    SELECT  @RangeCols  = COUNT(DISTINCT CASE WHEN IssueType = 'InvalidDateRange'     THEN DbName + '.' + SchemaName + '.' + TableName + '.' + ColumnName END),
            @FutureCols = COUNT(DISTINCT CASE WHEN IssueType = 'ProhibitedFutureDate' THEN DbName + '.' + SchemaName + '.' + TableName + '.' + ColumnName END),
            @TypeCols   = COUNT(DISTINCT CASE WHEN IssueType = 'NonDateStorageType'   THEN DbName + '.' + SchemaName + '.' + TableName + '.' + ColumnName END),
            @RangeRows  = SUM(CASE WHEN IssueType = 'InvalidDateRange'     THEN BadRows ELSE 0 END),
            @FutureRows = SUM(CASE WHEN IssueType = 'ProhibitedFutureDate' THEN BadRows ELSE 0 END)
    FROM    #DateFindings;

    SET @RangeCols  = ISNULL(@RangeCols, 0);
    SET @FutureCols = ISNULL(@FutureCols, 0);
    SET @TypeCols   = ISNULL(@TypeCols, 0);
    SET @RangeRows  = ISNULL(@RangeRows, 0);
    SET @FutureRows = ISNULL(@FutureRows, 0);

    SELECT @Detail = STUFF(
        ( SELECT TOP (5) N'; ' + f.DbName + N'.' + f.SchemaName + N'.' + f.TableName + N'.' + f.ColumnName
                       + N' [' + f.IssueType + N': ' + CAST(f.BadRows AS nvarchar(20)) + N' rows]'
          FROM   #DateFindings AS f
          WHERE  f.IssueType IN ('InvalidDateRange', 'ProhibitedFutureDate')
          ORDER  BY f.BadRows DESC, f.DbName, f.SchemaName, f.TableName, f.ColumnName
          FOR XML PATH(''), TYPE ).value('.', 'nvarchar(max)'), 1, 2, N'');

    SELECT @TypeDetail = STUFF(
        ( SELECT TOP (5) N'; ' + f.DbName + N'.' + f.SchemaName + N'.' + f.TableName + N'.' + f.ColumnName
          FROM   #DateFindings AS f
          WHERE  f.IssueType = 'NonDateStorageType'
          ORDER  BY f.DbName, f.SchemaName, f.TableName, f.ColumnName
          FOR XML PATH(''), TYPE ).value('.', 'nvarchar(max)'), 1, 2, N'');

    /* ---------------------------------------------------------------
       5. Score
       --------------------------------------------------------------- */
    IF @TotalDateCols = 0 AND @TypeCols = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'No date/time columns were found in user tables across the ' + CAST(@DbCount AS nvarchar(10))
                     + N' user database(s) queried, so there are no date ranges, storage inconsistencies or future-dated values to validate.';
    END
    ELSE IF @RangeCols = 0 AND @FutureCols = 0 AND @TypeCols = 0 AND @SkippedCols = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@TotalDateCols AS nvarchar(20)) + N' date/time column(s) across '
                     + CAST(@DbCount AS nvarchar(10)) + N' user database(s) hold values within the valid range '
                     + N'(>= 1900-01-01 and < 9999-01-01), no past-event column (created/modified/updated/birth/hire/received/posted/load) '
                     + N'contains a future-dated value, and no date-like column is stored in a text or numeric data type.';
    END
    ELSE IF @RangeCols = 0 AND @FutureCols = 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'No out-of-range or prohibited future date values were found across ' + CAST(@TotalDateCols AS nvarchar(20))
                     + N' date/time column(s) in ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s), but date handling is inconsistent: '
                     + CAST(@TypeCols AS nvarchar(20)) + N' date-like column(s) are stored in text/numeric data types'
                     + ISNULL(N' (e.g. ' + @TypeDetail + N')', N'') + N'. '
                     + CAST(@SkippedCols AS nvarchar(20)) + N' column(s) could not be profiled.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Date validity violations detected: ' + CAST(@RangeCols AS nvarchar(20)) + N' column(s) with '
                     + CAST(@RangeRows AS nvarchar(20)) + N' out-of-range/sentinel value(s) (< 1900-01-01 or >= 9999-01-01); '
                     + CAST(@FutureCols AS nvarchar(20)) + N' past-event column(s) with ' + CAST(@FutureRows AS nvarchar(20))
                     + N' future-dated value(s); ' + CAST(@TypeCols AS nvarchar(20))
                     + N' date-like column(s) stored in text/numeric types' + ISNULL(N' (e.g. ' + @TypeDetail + N')', N'') + N'. '
                     + N'Examples: ' + ISNULL(@Detail, N'n/a') + N'. '
                     + CAST(@SkippedCols AS nvarchar(20)) + N' column(s) could not be profiled.';
    END

    IF @ErrorMessage IS NOT NULL
        SET @Finding = @Finding + N' Collection error(s): ' + @ErrorMessage;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* -------------------------------------------------------------------
   6. Standard four-column output
   ------------------------------------------------------------------- */
SELECT  @Result          AS Result,
        @Score           AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Databases')    IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#DateColumns')  IS NOT NULL DROP TABLE #DateColumns;
IF OBJECT_ID('tempdb..#DateFindings') IS NOT NULL DROP TABLE #DateFindings;