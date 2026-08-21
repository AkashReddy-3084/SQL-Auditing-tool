/* Checklist 3.2.4 - Views used appropriately (no deeply nested view chains that hide cost)
   Read-only. Walks view -> view dependency edges in every accessible user database. */
SET NOCOUNT ON;

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#ViewNesting') IS NOT NULL DROP TABLE #ViewNesting;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;

CREATE TABLE #ViewNesting (
    DatabaseName  sysname       NOT NULL,
    TotalViews    int           NOT NULL,
    ViewsOnViews  int           NOT NULL,
    MaxChainDepth int           NOT NULL,
    DeepChains    int           NOT NULL,
    DeepestView   nvarchar(512) NULL
);

CREATE TABLE #Dbs (DatabaseName sysname NOT NULL PRIMARY KEY);

IF @IsAzureDb = 1
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @DbName sysname, @Sql nvarchar(max), @UseStmt nvarchar(300);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @UseStmt = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE N'USE ' + QUOTENAME(@DbName) + N';' END;

    SET @Sql = @UseStmt + N'
SET NOCOUNT ON;
DECLARE @Total int = 0, @Nested int = 0, @MaxDepth int = 0, @Deep int = 0;
DECLARE @DeepestView nvarchar(512) = NULL;

SELECT @Total = COUNT(*) FROM sys.views v WHERE v.is_ms_shipped = 0;

CREATE TABLE #vd (child_id int NOT NULL, parent_id int NOT NULL);

INSERT INTO #vd (child_id, parent_id)
SELECT DISTINCT d.referencing_id, d.referenced_id
FROM sys.sql_expression_dependencies d
INNER JOIN sys.views cv ON cv.object_id = d.referencing_id AND cv.is_ms_shipped = 0
INNER JOIN sys.views pv ON pv.object_id = d.referenced_id  AND pv.is_ms_shipped = 0
WHERE d.referencing_class = 1
  AND d.referenced_class = 1
  AND d.referenced_id IS NOT NULL
  AND d.referenced_id <> d.referencing_id;

SELECT @Nested = COUNT(DISTINCT child_id) FROM #vd;

CREATE TABLE #chain (root_id int NOT NULL, parent_id int NOT NULL, depth int NOT NULL);

WITH chain AS (
    SELECT e.child_id AS root_id, e.parent_id, 2 AS depth
    FROM #vd e
    UNION ALL
    SELECT c.root_id, n.parent_id, c.depth + 1
    FROM chain c
    INNER JOIN #vd n ON n.child_id = c.parent_id
    WHERE c.depth < 20
)
INSERT INTO #chain (root_id, parent_id, depth)
SELECT root_id, parent_id, depth FROM chain
OPTION (MAXRECURSION 32);

SELECT @MaxDepth = ISNULL(MAX(depth), 0) FROM #chain;

SELECT @Deep = COUNT(*)
FROM (SELECT root_id FROM #chain WHERE depth >= 4 GROUP BY root_id) x;

SELECT TOP (1) @DeepestView = QUOTENAME(s.name) + N''.'' + QUOTENAME(v.name)
FROM #chain c
INNER JOIN sys.views v   ON v.object_id = c.root_id
INNER JOIN sys.schemas s ON s.schema_id = v.schema_id
ORDER BY c.depth DESC, s.name, v.name;

INSERT INTO #ViewNesting (DatabaseName, TotalViews, ViewsOnViews, MaxChainDepth, DeepChains, DeepestView)
VALUES (@p_db, @Total, @Nested, @MaxDepth, @Deep, @DeepestView);

DROP TABLE #chain;
DROP TABLE #vd;';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql, N'@p_db sysname', @p_db = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #ViewNesting (DatabaseName, TotalViews, ViewsOnViews, MaxChainDepth, DeepChains, DeepestView)
        VALUES (@DbName, -1, -1, -1, -1, NULL);
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount     int = (SELECT COUNT(*) FROM #ViewNesting WHERE TotalViews >= 0);
DECLARE @FailedDbs   int = (SELECT COUNT(*) FROM #ViewNesting WHERE TotalViews < 0);
DECLARE @TotalViews  int = (SELECT ISNULL(SUM(TotalViews), 0)    FROM #ViewNesting WHERE TotalViews >= 0);
DECLARE @NestedTotal int = (SELECT ISNULL(SUM(ViewsOnViews), 0)  FROM #ViewNesting WHERE TotalViews >= 0);
DECLARE @MaxDepthAll int = (SELECT ISNULL(MAX(MaxChainDepth), 0) FROM #ViewNesting WHERE TotalViews >= 0);
DECLARE @DeepTotal   int = (SELECT ISNULL(SUM(DeepChains), 0)    FROM #ViewNesting WHERE TotalViews >= 0);

DECLARE @DbList nvarchar(max);
SELECT @DbList = STUFF((SELECT N', ' + n.DatabaseName
                        FROM #ViewNesting n
                        ORDER BY n.DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @DbList = ISNULL(@DbList, N'(no accessible user database)');

DECLARE @Worst nvarchar(max);
SELECT @Worst = STUFF((SELECT N'; ' + n.DatabaseName
                              + N' max depth ' + CONVERT(nvarchar(10), n.MaxChainDepth)
                              + ISNULL(N' (deepest view ' + n.DeepestView + N')', N'')
                       FROM #ViewNesting n
                       WHERE n.MaxChainDepth >= 3
                       ORDER BY n.MaxChainDepth DESC, n.DatabaseName
                       FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @Worst = ISNULL(@Worst, N'none');

DECLARE @Result nvarchar(50), @Score int, @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No accessible user database could be scanned, so view nesting could not be assessed. '
                 + CONVERT(nvarchar(10), @FailedDbs) + N' database(s) returned an error during enumeration.';
END
ELSE IF @TotalViews = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'No user-defined views exist in the ' + CONVERT(nvarchar(10), @DbCount)
                 + N' user database(s) scanned, so no nested view chains can hide query cost.';
END
ELSE IF @DeepTotal > 0 OR @MaxDepthAll >= 4
BEGIN
    SET @Score  = 1;
    SET @Finding = N'Deeply nested view chains found: ' + CONVERT(nvarchar(10), @DeepTotal)
                 + N' view(s) sit at the top of a chain 4 or more views deep (deepest chain = '
                 + CONVERT(nvarchar(10), @MaxDepthAll) + N' levels). Across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) there are ' + CONVERT(nvarchar(10), @TotalViews) + N' view(s), of which '
                 + CONVERT(nvarchar(10), @NestedTotal) + N' read from another view. Detail: ' + LEFT(@Worst, 900) + N'.';
END
ELSE IF @MaxDepthAll = 3
BEGIN
    SET @Score  = 2;
    SET @Finding = N'View nesting reaches 3 levels. Across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) there are ' + CONVERT(nvarchar(10), @TotalViews) + N' view(s), of which '
                 + CONVERT(nvarchar(10), @NestedTotal) + N' read from another view; no chain reaches 4 levels. Detail: '
                 + LEFT(@Worst, 900) + N'.';
END
ELSE
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Views are used flatly: the deepest view-on-view chain is ' + CONVERT(nvarchar(10), @MaxDepthAll)
                 + N' level(s). Across ' + CONVERT(nvarchar(10), @DbCount) + N' database(s) there are '
                 + CONVERT(nvarchar(10), @TotalViews) + N' view(s), of which ' + CONVERT(nvarchar(10), @NestedTotal)
                 + N' read from another view. No chain reaches the 3-level warning threshold.';
END

IF @DbCount > 0 AND @FailedDbs > 0
    SET @Finding = @Finding + N' Note: ' + CONVERT(nvarchar(10), @FailedDbs)
                 + N' database(s) could not be scanned and are excluded from the result.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #ViewNesting;
DROP TABLE #Dbs;