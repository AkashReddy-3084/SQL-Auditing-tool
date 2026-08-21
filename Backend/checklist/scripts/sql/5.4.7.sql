/* =====================================================================
   Checklist Item : 5.4.7 - Boolean / Flag: only expected values;
                    consistent representation across tables
   Scope          : DATABASE (iterates every qualifying user database)
   Type           : READ-ONLY assessment (catalog reads + SELECT probes)
   Output         : Result, Score, DatabaseQueried, Finding
   ===================================================================== */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @DatabaseQueried nvarchar(4000) = N'None';
DECLARE @Result          nvarchar(20);
DECLARE @Score           int            = 0;
DECLARE @Finding         nvarchar(4000) = N'No database found to be queried';
DECLARE @IsAzureDb       bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

BEGIN TRY

    IF OBJECT_ID('tempdb..#Dbs')         IS NOT NULL DROP TABLE #Dbs;
    IF OBJECT_ID('tempdb..#FlagColumns') IS NOT NULL DROP TABLE #FlagColumns;

    CREATE TABLE #Dbs (DbName sysname NOT NULL PRIMARY KEY);

    CREATE TABLE #FlagColumns
    (
        DbName         sysname       NOT NULL,
        SchemaName     sysname       NOT NULL,
        TableName      sysname       NOT NULL,
        ColumnName     sysname       NOT NULL,
        TypeName       sysname       NOT NULL,
        Category       varchar(10)   NOT NULL,
        BadValueCount  int           NULL,
        SampleBadValue nvarchar(100) NULL,
        CheckFailed    bit           NOT NULL DEFAULT (0)
    );

    /* ---- 1. Enumerate qualifying user databases ---------------------- */
    IF @IsAzureDb = 1
    BEGIN
        INSERT INTO #Dbs (DbName)
        SELECT DB_NAME()
        WHERE DB_NAME() NOT IN ('master','tempdb','model','msdb');
    END
    ELSE
    BEGIN
        INSERT INTO #Dbs (DbName)
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.name NOT IN ('master','model','msdb','tempdb')
          AND d.state_desc = 'ONLINE'
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1;
    END

    IF NOT EXISTS (SELECT 1 FROM #Dbs)
    BEGIN
        SET @DatabaseQueried = N'None';
        SET @Finding         = N'No database found to be queried';
        SET @Score           = 0;
    END
    ELSE
    BEGIN

        DECLARE @DbList nvarchar(3000) = N'';
        SELECT @DbList = @DbList + N', ' + DbName FROM #Dbs ORDER BY DbName;
        SET @DatabaseQueried = CASE WHEN LEN(@DbList) > 2 THEN LEFT(STUFF(@DbList, 1, 2, N''), 3900) ELSE N'None' END;

        DECLARE @db sysname, @pfx nvarchar(300), @sql nvarchar(max);
        DECLARE @DbFailed int = 0;

        /* ---- 2. Collect flag-like columns from each database --------- */
        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DbName FROM #Dbs ORDER BY DbName;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @pfx = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

            BEGIN TRY
                SET @sql =
                    N'INSERT INTO #FlagColumns (DbName, SchemaName, TableName, ColumnName, TypeName, Category) ' +
                    N'SELECT @db_in, s.name, t.name, c.name, ty.name, ' +
                    N'       CASE WHEN ty.name = ''bit'' THEN ''BIT'' ' +
                    N'            WHEN ty.name IN (''char'',''nchar'',''varchar'',''nvarchar'') THEN ''CHAR'' ' +
                    N'            ELSE ''NUMERIC'' END ' +
                    N'FROM ' + @pfx + N'sys.columns  AS c ' +
                    N'INNER JOIN ' + @pfx + N'sys.tables  AS t  ON t.object_id     = c.object_id ' +
                    N'INNER JOIN ' + @pfx + N'sys.schemas AS s  ON s.schema_id     = t.schema_id ' +
                    N'INNER JOIN ' + @pfx + N'sys.types   AS ty ON ty.user_type_id = c.user_type_id ' +
                    N'WHERE t.is_ms_shipped = 0 ' +
                    N'  AND t.type = ''U'' ' +
                    N'  AND s.name NOT IN (''sys'',''INFORMATION_SCHEMA'') ' +
                    N'  AND c.is_computed = 0 ' +
                    N'  AND ( ty.name = ''bit'' ' +
                    N'        OR ( ( (ty.name IN (''char'',''varchar'')   AND c.max_length BETWEEN 1 AND 5) ' +
                    N'              OR (ty.name IN (''nchar'',''nvarchar'') AND c.max_length BETWEEN 1 AND 10) ' +
                    N'              OR (ty.name IN (''tinyint'',''smallint'',''int'')) ) ' +
                    N'             AND ( c.name LIKE ''Is%'' OR c.name LIKE ''Has%'' OR c.name LIKE ''Can%'' ' +
                    N'                OR c.name LIKE ''%Flag'' OR c.name LIKE ''%Flg'' ' +
                    N'                OR c.name LIKE ''%Enabled'' OR c.name LIKE ''%Active'' ' +
                    N'                OR c.name LIKE ''%Deleted'' OR c.name LIKE ''%Indicator'' ' +
                    N'                OR c.name LIKE ''%[_]YN'' OR c.name LIKE ''%[_]IND'' ) ) );';

                EXEC sp_executesql @sql, N'@db_in sysname', @db_in = @db;
            END TRY
            BEGIN CATCH
                SET @DbFailed = @DbFailed + 1;
            END CATCH

            FETCH NEXT FROM db_cur INTO @db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;

        /* ---- 3. Probe non-bit flag columns for unexpected values ----- */
        DECLARE @sch sysname, @tab sysname, @col sysname, @cat varchar(10);
        DECLARE @expected nvarchar(400), @objRef nvarchar(800);
        DECLARE @cnt int, @sample nvarchar(100);

        DECLARE flag_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DbName, SchemaName, TableName, ColumnName, Category
            FROM #FlagColumns
            WHERE Category <> 'BIT';

        OPEN flag_cur;
        FETCH NEXT FROM flag_cur INTO @db, @sch, @tab, @col, @cat;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @pfx      = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;
            SET @objRef   = @pfx + QUOTENAME(@sch) + N'.' + QUOTENAME(@tab);
            SET @expected = CASE WHEN @cat = 'CHAR'
                                 THEN N'''0'',''1'',''Y'',''N'',''T'',''F'',''YES'',''NO'',''TRUE'',''FALSE'''
                                 ELSE N'''0'',''1'''
                            END;
            SET @cnt    = NULL;
            SET @sample = NULL;

            BEGIN TRY
                SET @sql =
                    N'SELECT @cnt_out = COUNT(*), @sample_out = MIN(x.v) FROM (' +
                    N'SELECT DISTINCT TOP (25) CONVERT(nvarchar(100), ' + QUOTENAME(@col) + N') AS v ' +
                    N'FROM ' + @objRef + N' ' +
                    N'WHERE ' + QUOTENAME(@col) + N' IS NOT NULL ' +
                    N'AND UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100), ' + QUOTENAME(@col) + N')))) NOT IN (' + @expected + N')' +
                    N') AS x;';

                EXEC sp_executesql
                     @sql,
                     N'@cnt_out int OUTPUT, @sample_out nvarchar(100) OUTPUT',
                     @cnt_out = @cnt OUTPUT, @sample_out = @sample OUTPUT;

                UPDATE #FlagColumns
                   SET BadValueCount  = ISNULL(@cnt, 0),
                       SampleBadValue = @sample
                 WHERE DbName = @db AND SchemaName = @sch AND TableName = @tab AND ColumnName = @col;
            END TRY
            BEGIN CATCH
                UPDATE #FlagColumns
                   SET CheckFailed = 1
                 WHERE DbName = @db AND SchemaName = @sch AND TableName = @tab AND ColumnName = @col;
            END CATCH

            FETCH NEXT FROM flag_cur INTO @db, @sch, @tab, @col, @cat;
        END

        CLOSE flag_cur;
        DEALLOCATE flag_cur;

        /* ---- 4. Aggregate -------------------------------------------- */
        DECLARE @DbCount int = 0, @Total int = 0, @BitCols int = 0, @CharCols int = 0,
                @NumCols int = 0, @BadCols int = 0, @Unchecked int = 0, @MixedDbs int = 0;

        SELECT @DbCount = COUNT(*) FROM #Dbs;

        SELECT @Total     = COUNT(*),
               @BitCols   = SUM(CASE WHEN Category = 'BIT'     THEN 1 ELSE 0 END),
               @CharCols  = SUM(CASE WHEN Category = 'CHAR'    THEN 1 ELSE 0 END),
               @NumCols   = SUM(CASE WHEN Category = 'NUMERIC' THEN 1 ELSE 0 END),
               @BadCols   = SUM(CASE WHEN ISNULL(BadValueCount, 0) > 0 THEN 1 ELSE 0 END),
               @Unchecked = SUM(CASE WHEN CheckFailed = 1 THEN 1 ELSE 0 END)
        FROM #FlagColumns;

        SET @Total     = ISNULL(@Total, 0);
        SET @BitCols   = ISNULL(@BitCols, 0);
        SET @CharCols  = ISNULL(@CharCols, 0);
        SET @NumCols   = ISNULL(@NumCols, 0);
        SET @BadCols   = ISNULL(@BadCols, 0);
        SET @Unchecked = ISNULL(@Unchecked, 0);

        SELECT @MixedDbs = COUNT(*)
        FROM (
            SELECT DbName
            FROM #FlagColumns
            GROUP BY DbName
            HAVING COUNT(DISTINCT Category) > 1
        ) AS m;

        SET @MixedDbs = ISNULL(@MixedDbs, 0);

        DECLARE @MixedList nvarchar(800) = N'';
        SELECT TOP (5) @MixedList = @MixedList + DbName + N', '
        FROM (
            SELECT DbName
            FROM #FlagColumns
            GROUP BY DbName
            HAVING COUNT(DISTINCT Category) > 1
        ) AS m2
        ORDER BY DbName;

        DECLARE @BadList nvarchar(1500) = N'';
        SELECT TOP (5)
               @BadList = @BadList + DbName + N'.' + SchemaName + N'.' + TableName + N'.' + ColumnName
                        + N' [' + TypeName + N', e.g. "' + ISNULL(SampleBadValue, N'') + N'"]; '
        FROM #FlagColumns
        WHERE ISNULL(BadValueCount, 0) > 0
        ORDER BY DbName, SchemaName, TableName, ColumnName;

        DECLARE @Mix nvarchar(200) =
                N'BIT=' + CAST(@BitCols AS nvarchar(10)) +
                N', CHAR=' + CAST(@CharCols AS nvarchar(10)) +
                N', NUMERIC=' + CAST(@NumCols AS nvarchar(10));

        /* ---- 5. Score ------------------------------------------------ */
        IF @Total = 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'No boolean/flag columns were identified across the ' + CAST(@DbCount AS nvarchar(10)) +
                           N' user database(s) scanned (no bit columns and no short char/integer columns matching flag naming patterns), so there is no inconsistent representation or unexpected flag value to report.';
        END
        ELSE IF @BadCols = 0 AND @MixedDbs = 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'All ' + CAST(@Total AS nvarchar(10)) + N' boolean/flag columns across ' + CAST(@DbCount AS nvarchar(10)) +
                           N' user database(s) use a single consistent representation per database (' + @Mix +
                           N') and no column stores a value outside the accepted boolean set.';
        END
        ELSE IF @BadCols = 0 AND @MixedDbs > 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'Stored values are all valid, but ' + CAST(@MixedDbs AS nvarchar(10)) +
                           N' of ' + CAST(@DbCount AS nvarchar(10)) + N' database(s) model boolean/flag columns with more than one representation. Overall mix across ' +
                           CAST(@Total AS nvarchar(10)) + N' flag columns: ' + @Mix + N'. Affected database(s): ' +
                           CASE WHEN @MixedList = N'' THEN N'(none captured)' ELSE @MixedList END;
        END
        ELSE IF @BadCols * 10 <= @Total
        BEGIN
            SET @Score   = 1;
            SET @Finding = CAST(@BadCols AS nvarchar(10)) + N' of ' + CAST(@Total AS nvarchar(10)) +
                           N' boolean/flag columns store values outside the accepted boolean set. Representation mix: ' + @Mix +
                           N'. Databases mixing representations: ' + CAST(@MixedDbs AS nvarchar(10)) +
                           N'. Examples: ' + CASE WHEN @BadList = N'' THEN N'(none captured)' ELSE @BadList END;
        END
        ELSE
        BEGIN
            SET @Score   = 0;
            SET @Finding = CAST(@BadCols AS nvarchar(10)) + N' of ' + CAST(@Total AS nvarchar(10)) +
                           N' boolean/flag columns store values outside the accepted boolean set. Representation mix: ' + @Mix +
                           N'. Databases mixing representations: ' + CAST(@MixedDbs AS nvarchar(10)) +
                           N'. Examples: ' + CASE WHEN @BadList = N'' THEN N'(none captured)' ELSE @BadList END;
        END

        IF @DbFailed > 0
            SET @Finding = @Finding + N' Note: ' + CAST(@DbFailed AS nvarchar(10)) +
                           N' database(s) could not be read and were excluded.';

        IF @Unchecked > 0
            SET @Finding = @Finding + N' Note: ' + CAST(@Unchecked AS nvarchar(10)) +
                           N' flag column(s) could not be read (permissions or inaccessible object) and were excluded from the value check.';
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    IF OBJECT_ID('tempdb..#FlagColumns') IS NOT NULL DROP TABLE #FlagColumns;
    IF OBJECT_ID('tempdb..#Dbs')         IS NOT NULL DROP TABLE #Dbs;

    SELECT @Result                    AS Result,
           @Score                     AS Score,
           LEFT(@DatabaseQueried,3900) AS DatabaseQueried,
           LEFT(@Finding,3900)         AS Finding;

END TRY
BEGIN CATCH

    IF CURSOR_STATUS('local','flag_cur') > -3
    BEGIN
        IF CURSOR_STATUS('local','flag_cur') > -1 CLOSE flag_cur;
        DEALLOCATE flag_cur;
    END

    IF CURSOR_STATUS('local','db_cur') > -3
    BEGIN
        IF CURSOR_STATUS('local','db_cur') > -1 CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    IF OBJECT_ID('tempdb..#FlagColumns') IS NOT NULL DROP TABLE #FlagColumns;
    IF OBJECT_ID('tempdb..#Dbs')         IS NOT NULL DROP TABLE #Dbs;

    SET @Score   = 0;
    SET @Result  = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'Boolean/flag column evaluation could not be completed: ' + ERROR_MESSAGE();

    SELECT @Result                    AS Result,
           @Score                     AS Score,
           LEFT(@DatabaseQueried,3900) AS DatabaseQueried,
           LEFT(@Finding,3900)         AS Finding;

END CATCH