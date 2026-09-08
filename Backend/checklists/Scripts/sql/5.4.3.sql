SET NOCOUNT ON;

DECLARE @Result VARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = N'None';
DECLARE @Finding NVARCHAR(MAX) = N'No database found to be queried';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @DbName_A NVARCHAR(128) = DB_NAME();
    DECLARE @DbCollation_A NVARCHAR(128) = CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(@DbName_A, 'Collation'));
    DECLARE @AnsiWarnings_A BIT;
    DECLARE @StringCols_A INT = 0;
    DECLARE @MixedColl_A INT = 0;
    DECLARE @DistinctColl_A INT = 0;
    DECLARE @Unbounded_A INT = 0;
    DECLARE @MixedPct_A DECIMAL(5, 2) = 0;
    DECLARE @Issues_A INT = 0;

    SELECT @AnsiWarnings_A = is_ansi_warnings_on
    FROM sys.databases
    WHERE database_id = DB_ID();

    SELECT
        @StringCols_A = COUNT(*),
        @MixedColl_A = SUM(CASE WHEN c.collation_name IS NOT NULL AND c.collation_name <> @DbCollation_A THEN 1 ELSE 0 END),
        @DistinctColl_A = COUNT(DISTINCT c.collation_name),
        @Unbounded_A = SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END)
    FROM sys.columns AS c
    INNER JOIN sys.types AS t ON c.user_type_id = t.user_type_id
    INNER JOIN sys.tables AS tb ON c.object_id = tb.object_id
    WHERE tb.is_ms_shipped = 0
      AND t.name IN (N'char', N'varchar', N'nchar', N'nvarchar', N'text', N'ntext');

    SET @StringCols_A = ISNULL(@StringCols_A, 0);
    SET @MixedColl_A = ISNULL(@MixedColl_A, 0);
    SET @DistinctColl_A = ISNULL(@DistinctColl_A, 0);
    SET @Unbounded_A = ISNULL(@Unbounded_A, 0);
    SET @AnsiWarnings_A = ISNULL(@AnsiWarnings_A, 1);
    SET @DatabaseQueried = @DbName_A;

    IF @StringCols_A = 0
    BEGIN
        SET @Score = 3;
        SET @Result = 'Pass';
        SET @Finding = N'Database ' + @DbName_A + N': no user-table string columns found; nothing to evaluate for collation or length consistency.';
    END
    ELSE
    BEGIN
        SET @MixedPct_A = (100.0 * @MixedColl_A) / @StringCols_A;
        SET @Issues_A = 0;

        IF @MixedPct_A > 25 OR @DistinctColl_A > 3
            SET @Issues_A = 3;
        ELSE IF @MixedPct_A >= 5 OR @DistinctColl_A > 1
            SET @Issues_A = 2;
        ELSE IF @MixedColl_A > 0
            SET @Issues_A = 1;

        IF @AnsiWarnings_A = 0
            SET @Issues_A = @Issues_A + 2;

        IF @Issues_A = 0
            SET @Score = 3;
        ELSE IF @Issues_A = 1
            SET @Score = 2;
        ELSE IF @Issues_A <= 3
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Result = CASE WHEN @Score = 3 THEN 'Pass' WHEN @Score = 0 THEN 'Fail' ELSE 'Partial' END;
        SET @Finding = N'Database ' + @DbName_A
            + N': string_cols=' + CONVERT(NVARCHAR(20), @StringCols_A)
            + N'; mixed_collation_cols=' + CONVERT(NVARCHAR(20), @MixedColl_A)
            + N' (' + CONVERT(NVARCHAR(20), CONVERT(DECIMAL(5, 1), @MixedPct_A)) + N'%)'
            + N'; distinct_collations=' + CONVERT(NVARCHAR(20), @DistinctColl_A)
            + N'; db_collation=' + ISNULL(@DbCollation_A, N'n/a')
            + N'; ANSI_WARNINGS=' + CASE WHEN @AnsiWarnings_A = 1 THEN N'ON' ELSE N'OFF' END
            + N'; max_length_MAX_cols=' + CONVERT(NVARCHAR(20), @Unbounded_A)
            + N'.';
    END
END
ELSE
BEGIN
    CREATE TABLE #DbResults (
        DbName NVARCHAR(128) NOT NULL,
        StringCols INT NOT NULL,
        MixedColl INT NOT NULL,
        DistinctColl INT NOT NULL,
        UnboundedCols INT NOT NULL,
        AnsiWarnings BIT NOT NULL,
        DbCollation NVARCHAR(128) NULL,
        DbScore INT NOT NULL,
        Detail NVARCHAR(500) NOT NULL
    );

    DECLARE @DbName NVARCHAR(128);
    DECLARE @DbCollation NVARCHAR(128);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @StringCols INT;
    DECLARE @MixedColl INT;
    DECLARE @DistinctColl INT;
    DECLARE @Unbounded INT;
    DECLARE @AnsiWarnings BIT;
    DECLARE @MixedPct DECIMAL(5, 2);
    DECLARE @Issues INT;
    DECLARE @DbScore INT;
    DECLARE @DbCount INT;
    DECLARE @PassDbs INT;
    DECLARE @PartialDbs INT;
    DECLARE @FailDbs INT;
    DECLARE @TotalString INT;
    DECLARE @TotalMixed INT;
    DECLARE @AnsiOff INT;
    DECLARE @DetailAgg NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name, collation_name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = N'ONLINE'
          AND is_read_only = 0
          AND name NOT IN (N'master', N'tempdb', N'model', N'msdb');

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName, @DbCollation;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @StringCols = 0;
        SET @MixedColl = 0;
        SET @DistinctColl = 0;
        SET @Unbounded = 0;
        SET @AnsiWarnings = 1;
        SET @MixedPct = 0;
        SET @Issues = 0;
        SET @DbScore = 3;

        SET @Sql = N'
SELECT
    @StringColsOut = COUNT(*),
    @MixedCollOut = SUM(CASE WHEN c.collation_name IS NOT NULL AND c.collation_name <> @DbCollIn THEN 1 ELSE 0 END),
    @DistinctCollOut = COUNT(DISTINCT c.collation_name),
    @UnboundedOut = SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END),
    @AnsiOut = d.is_ansi_warnings_on
FROM ' + QUOTENAME(@DbName) + N'.sys.columns AS c
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.types AS t ON c.user_type_id = t.user_type_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS tb ON c.object_id = tb.object_id
CROSS JOIN sys.databases AS d
WHERE tb.is_ms_shipped = 0
  AND d.name = @DbNameIn
  AND t.name IN (N''char'', N''varchar'', N''nchar'', N''nvarchar'', N''text'', N''ntext'');';

        BEGIN TRY
            EXEC sp_executesql
                @Sql,
                N'@DbCollIn NVARCHAR(128), @DbNameIn NVARCHAR(128),
                  @StringColsOut INT OUTPUT, @MixedCollOut INT OUTPUT,
                  @DistinctCollOut INT OUTPUT, @UnboundedOut INT OUTPUT,
                  @AnsiOut BIT OUTPUT',
                @DbCollIn = @DbCollation,
                @DbNameIn = @DbName,
                @StringColsOut = @StringCols OUTPUT,
                @MixedCollOut = @MixedColl OUTPUT,
                @DistinctCollOut = @DistinctColl OUTPUT,
                @UnboundedOut = @Unbounded OUTPUT,
                @AnsiOut = @AnsiWarnings OUTPUT;

            SET @StringCols = ISNULL(@StringCols, 0);
            SET @MixedColl = ISNULL(@MixedColl, 0);
            SET @DistinctColl = ISNULL(@DistinctColl, 0);
            SET @Unbounded = ISNULL(@Unbounded, 0);
            SET @AnsiWarnings = ISNULL(@AnsiWarnings, 1);

            IF @StringCols = 0
            BEGIN
                SET @DbScore = 3;
                SET @MixedPct = 0;
            END
            ELSE
            BEGIN
                SET @MixedPct = (100.0 * @MixedColl) / @StringCols;
                SET @Issues = 0;

                IF @MixedPct > 25 OR @DistinctColl > 3
                    SET @Issues = 3;
                ELSE IF @MixedPct >= 5 OR @DistinctColl > 1
                    SET @Issues = 2;
                ELSE IF @MixedColl > 0
                    SET @Issues = 1;

                IF @AnsiWarnings = 0
                    SET @Issues = @Issues + 2;

                IF @Issues = 0
                    SET @DbScore = 3;
                ELSE IF @Issues = 1
                    SET @DbScore = 2;
                ELSE IF @Issues <= 3
                    SET @DbScore = 1;
                ELSE
                    SET @DbScore = 0;
            END

            INSERT INTO #DbResults (DbName, StringCols, MixedColl, DistinctColl, UnboundedCols, AnsiWarnings, DbCollation, DbScore, Detail)
            VALUES (
                @DbName,
                @StringCols,
                @MixedColl,
                @DistinctColl,
                @Unbounded,
                @AnsiWarnings,
                @DbCollation,
                @DbScore,
                N'str=' + CONVERT(NVARCHAR(20), @StringCols)
                    + N'; mix=' + CONVERT(NVARCHAR(20), @MixedColl)
                    + N' (' + CONVERT(NVARCHAR(20), CONVERT(DECIMAL(5, 1), @MixedPct)) + N'%)'
                    + N' colls=' + CONVERT(NVARCHAR(20), @DistinctColl)
                    + N' ANSI_W=' + CASE WHEN @AnsiWarnings = 1 THEN N'ON' ELSE N'OFF' END
                    + N' MAX_cols=' + CONVERT(NVARCHAR(20), @Unbounded)
            );
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, StringCols, MixedColl, DistinctColl, UnboundedCols, AnsiWarnings, DbCollation, DbScore, Detail)
            VALUES (
                @DbName, 0, 0, 0, 0, 1, @DbCollation, 0,
                N'Evaluation failed: ' + LEFT(ERROR_MESSAGE(), 200)
            );
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName, @DbCollation;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    IF NOT EXISTS (SELECT 1 FROM #DbResults)
    BEGIN
        SET @DatabaseQueried = N'None';
        SET @Finding = N'No database found to be queried';
        SET @Score = 0;
        SET @Result = 'Fail';
    END
    ELSE
    BEGIN
        SELECT @DatabaseQueried = ISNULL(STUFF((
            SELECT N',' + r.DbName
            FROM #DbResults AS r
            ORDER BY r.DbName
            FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 1, N''), N'None');

        SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;

        SELECT @DbCount = COUNT(*) FROM #DbResults;
        SELECT @PassDbs = COUNT(*) FROM #DbResults WHERE DbScore = 3;
        SELECT @PartialDbs = COUNT(*) FROM #DbResults WHERE DbScore IN (1, 2);
        SELECT @FailDbs = COUNT(*) FROM #DbResults WHERE DbScore = 0;
        SELECT @TotalString = ISNULL(SUM(StringCols), 0) FROM #DbResults;
        SELECT @TotalMixed = ISNULL(SUM(MixedColl), 0) FROM #DbResults;
        SELECT @AnsiOff = COUNT(*) FROM #DbResults WHERE AnsiWarnings = 0;

        SELECT @DetailAgg = ISNULL(STUFF((
            SELECT N' | ' + r.DbName + N': ' + r.Detail
            FROM #DbResults AS r
            ORDER BY r.DbScore ASC, r.DbName
            FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 3, N''), N'');

        SET @Result = CASE WHEN @Score = 3 THEN 'Pass' WHEN @Score = 0 THEN 'Fail' ELSE 'Partial' END;
        SET @Finding = N'Evaluated ' + CONVERT(NVARCHAR(20), @DbCount)
            + N' database(s); Pass=' + CONVERT(NVARCHAR(20), @PassDbs)
            + N', Partial=' + CONVERT(NVARCHAR(20), @PartialDbs)
            + N', Fail=' + CONVERT(NVARCHAR(20), @FailDbs)
            + N'; total_string_cols=' + CONVERT(NVARCHAR(20), @TotalString)
            + N', mixed_collation_cols=' + CONVERT(NVARCHAR(20), @TotalMixed)
            + N', ANSI_WARNINGS_OFF_dbs=' + CONVERT(NVARCHAR(20), @AnsiOff)
            + N'. ' + @DetailAgg;
    END

    DROP TABLE #DbResults;
END

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;