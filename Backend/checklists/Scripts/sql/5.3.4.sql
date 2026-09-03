SET NOCOUNT ON;

DECLARE @Result varchar(10) = 'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding nvarchar(max) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList
(
    DatabaseName sysname NOT NULL
);

IF OBJECT_ID('tempdb..#AggFindings') IS NOT NULL DROP TABLE #AggFindings;
CREATE TABLE #AggFindings
(
    DatabaseName sysname NOT NULL,
    AggregateObjectCount int NOT NULL,
    DetailObjectCount int NOT NULL,
    ReconcileModuleCount int NOT NULL,
    PairedAggregateCount int NOT NULL
);

DECLARE @IsAzure bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF @IsAzure = 1
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName sysname;
DECLARE @Sql nvarchar(max);
DECLARE @AggCount int;
DECLARE @DetCount int;
DECLARE @RecCount int;
DECLARE @PairCount int;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @AggCount = 0;
    SET @DetCount = 0;
    SET @RecCount = 0;
    SET @PairCount = 0;

    SET @Sql = N'
    SELECT
        @AggOut = COUNT(DISTINCT CASE
            WHEN (
                o.name LIKE N''%agg%''
                OR o.name LIKE N''%aggregat%''
                OR o.name LIKE N''%summary%''
                OR o.name LIKE N''%summar%''
                OR o.name LIKE N''%rollup%''
                OR o.name LIKE N''%total%''
                OR s.name LIKE N''%agg%''
                OR s.name LIKE N''%summary%''
            ) AND o.type IN (''U'', ''V'')
            THEN o.object_id END),
        @DetOut = COUNT(DISTINCT CASE
            WHEN (
                o.name LIKE N''%detail%''
                OR o.name LIKE N''%fact%''
                OR o.name LIKE N''%txn%''
                OR o.name LIKE N''%transact%''
                OR o.name LIKE N''%line%''
                OR s.name LIKE N''%detail%''
                OR s.name LIKE N''%fact%''
            ) AND o.type IN (''U'', ''V'')
            THEN o.object_id END),
        @RecOut = COUNT(DISTINCT CASE
            WHEN o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'')
             AND (
                m.definition LIKE N''%reconcil%''
                OR m.definition LIKE N''%aggregate%consistency%''
                OR m.definition LIKE N''%detail%sum%''
                OR o.name LIKE N''%reconcil%''
                OR o.name LIKE N''%agg%check%''
                OR o.name LIKE N''%consist%''
                OR o.name LIKE N''%balance%''
             )
            THEN o.object_id END),
        @PairOut = COUNT(DISTINCT CASE
            WHEN o.type IN (''U'', ''V'')
             AND (
                o.name LIKE N''%agg%''
                OR o.name LIKE N''%aggregat%''
                OR o.name LIKE N''%summary%''
                OR o.name LIKE N''%rollup%''
                OR o.name LIKE N''%total%''
             )
             AND EXISTS (
                SELECT 1
                FROM ' + QUOTENAME(@DbName) + N'.sys.objects d
                WHERE d.type IN (''U'', ''V'')
                  AND d.is_ms_shipped = 0
                  AND (
                        d.name LIKE N''%detail%''
                     OR d.name LIKE N''%fact%''
                     OR d.name LIKE N''%txn%''
                     OR d.name LIKE N''%line%''
                  )
                  AND (
                        REPLACE(REPLACE(LOWER(o.name), ''aggregate'', ''''), ''agg'', '''') LIKE N''%'' + REPLACE(REPLACE(LOWER(d.name), ''detail'', ''''), ''fact'', '''') + N''%''
                     OR REPLACE(REPLACE(LOWER(d.name), ''detail'', ''''), ''fact'', '''') LIKE N''%'' + REPLACE(REPLACE(LOWER(o.name), ''aggregate'', ''''), ''agg'', '''') + N''%''
                     OR LEFT(LOWER(o.name), 6) = LEFT(LOWER(d.name), 6)
                  )
             )
            THEN o.object_id END)
    FROM ' + QUOTENAME(@DbName) + N'.sys.objects o
    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON s.schema_id = o.schema_id
    LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0;
    ';

    BEGIN TRY
        EXEC sp_executesql
            @Sql,
            N'@AggOut int OUTPUT, @DetOut int OUTPUT, @RecOut int OUTPUT, @PairOut int OUTPUT',
            @AggOut = @AggCount OUTPUT,
            @DetOut = @DetCount OUTPUT,
            @RecOut = @RecCount OUTPUT,
            @PairOut = @PairCount OUTPUT;

        INSERT INTO #AggFindings (DatabaseName, AggregateObjectCount, DetailObjectCount, ReconcileModuleCount, PairedAggregateCount)
        VALUES (@DbName, @AggCount, @DetCount, @RecCount, @PairCount);
    END TRY
    BEGIN CATCH
        -- Skip databases that cannot be scanned
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF EXISTS (SELECT 1 FROM #AggFindings)
BEGIN
    DECLARE @DbCount int;
    DECLARE @TotalAgg int;
    DECLARE @TotalDet int;
    DECLARE @TotalRec int;
    DECLARE @TotalPair int;
    DECLARE @CoveredAgg int;
    DECLARE @CoveragePct decimal(5, 2);

    SELECT
        @DbCount = COUNT(*),
        @TotalAgg = SUM(AggregateObjectCount),
        @TotalDet = SUM(DetailObjectCount),
        @TotalRec = SUM(ReconcileModuleCount),
        @TotalPair = SUM(PairedAggregateCount)
    FROM #AggFindings;

    SET @CoveredAgg = CASE WHEN @TotalPair > @TotalAgg THEN @TotalAgg ELSE @TotalPair END;
    IF @TotalRec > 0 AND @CoveredAgg < @TotalAgg
        SET @CoveredAgg = CASE
            WHEN @CoveredAgg + CASE WHEN @TotalRec > @TotalAgg THEN @TotalAgg ELSE @TotalRec END > @TotalAgg
                THEN @TotalAgg
            ELSE @CoveredAgg + CASE WHEN @TotalRec > @TotalAgg THEN @TotalAgg ELSE @TotalRec END
        END;

    SET @CoveragePct = CASE WHEN ISNULL(@TotalAgg, 0) = 0 THEN 0.00
                            ELSE CAST(@CoveredAgg AS decimal(10, 2)) * 100.0 / CAST(@TotalAgg AS decimal(10, 2))
                       END;

    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + DatabaseName
        FROM #AggFindings
        ORDER BY DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @DatabaseQueried IS NULL OR LTRIM(RTRIM(@DatabaseQueried)) = N''
        SET @DatabaseQueried = N'None';

    IF @TotalAgg = 0 AND @TotalRec = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10))
            + N' database(s); found no aggregate/summary objects and no reconciliation modules evidencing detail-to-aggregate consistency checks.';
    END
    ELSE IF @TotalAgg = 0 AND @TotalRec > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10))
            + N' database(s); no clearly named aggregate/summary tables/views, but found '
            + CAST(@TotalRec AS varchar(10))
            + N' reconciliation/consistency module(s). Detail objects observed: '
            + CAST(@TotalDet AS varchar(10)) + N'.';
    END
    ELSE IF @CoveragePct >= 75.0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10))
            + N' database(s); aggregate objects=' + CAST(@TotalAgg AS varchar(10))
            + N', paired/reconciled=' + CAST(@CoveredAgg AS varchar(10))
            + N' (' + CAST(CAST(@CoveragePct AS decimal(5,1)) AS varchar(10))
            + N'%), detail objects=' + CAST(@TotalDet AS varchar(10))
            + N', reconcile modules=' + CAST(@TotalRec AS varchar(10)) + N'.';
    END
    ELSE IF @CoveragePct >= 50.0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10))
            + N' database(s); aggregate objects=' + CAST(@TotalAgg AS varchar(10))
            + N', paired/reconciled=' + CAST(@CoveredAgg AS varchar(10))
            + N' (' + CAST(CAST(@CoveragePct AS decimal(5,1)) AS varchar(10))
            + N'%), detail objects=' + CAST(@TotalDet AS varchar(10))
            + N', reconcile modules=' + CAST(@TotalRec AS varchar(10)) + N'. Partial aggregate consistency coverage.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Scanned ' + CAST(@DbCount AS varchar(10))
            + N' database(s); aggregate objects=' + CAST(@TotalAgg AS varchar(10))
            + N', paired/reconciled=' + CAST(@CoveredAgg AS varchar(10))
            + N' (' + CAST(CAST(@CoveragePct AS decimal(5,1)) AS varchar(10))
            + N'%), detail objects=' + CAST(@TotalDet AS varchar(10))
            + N', reconcile modules=' + CAST(@TotalRec AS varchar(10))
            + N'. Weak evidence that detail sums are checked against aggregate totals.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;