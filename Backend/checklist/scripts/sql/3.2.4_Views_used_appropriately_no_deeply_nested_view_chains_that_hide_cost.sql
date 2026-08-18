-- Checklist: Views used appropriately (no deeply nested view chains that hide cost)
-- Scope: DATABASE
-- Scoring: 3: No view chains deeper than 3 levels. 2: Max depth <= 5. 1: Max depth <= 8. 0: Max depth > 8.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @MaxDepth INT;
DECLARE @DeepViews NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

CREATE TABLE #DeepViews (ViewName NVARCHAR(128), MaxDepth INT);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    ;WITH ViewChain AS (
        SELECT
            referencing_id AS view_id,
            referenced_id AS dep_id,
            1 AS chain_depth
        FROM sys.sql_expression_dependencies sed
        INNER JOIN sys.views v ON sed.referencing_id = v.object_id
        INNER JOIN sys.views v2 ON sed.referenced_id = v2.object_id
        WHERE sed.class = 1
        UNION ALL
        SELECT
            vc.view_id,
            sed.referenced_id,
            vc.chain_depth + 1
        FROM ViewChain vc
        INNER JOIN sys.sql_expression_dependencies sed ON vc.dep_id = sed.referencing_id
        INNER JOIN sys.views v2 ON sed.referenced_id = v2.object_id
        WHERE sed.class = 1
          AND vc.chain_depth < 10
    )
    SELECT
        OBJECT_NAME(view_id) AS ViewName,
        MAX(chain_depth) AS MaxDepth
    FROM ViewChain
    GROUP BY view_id
    HAVING MAX(chain_depth) > 3
    ORDER BY MaxDepth DESC;
    ';

    TRUNCATE TABLE #DeepViews;
    INSERT INTO #DeepViews EXEC sp_executesql @Sql;

    SELECT @MaxDepth = MAX(MaxDepth), @DeepViews = STRING_AGG(ViewName + ' (depth: ' + CAST(MaxDepth AS NVARCHAR) + ')', ', ') FROM #DeepViews;

    IF @MaxDepth IS NULL SET @MaxDepth = 0;

    SET @Score = CASE
        WHEN @MaxDepth <= 3 THEN 3
        WHEN @MaxDepth <= 5 THEN 2
        WHEN @MaxDepth <= 8 THEN 1
        ELSE 0
    END;

    SET @Finding = CASE
        WHEN @MaxDepth <= 3 THEN 'No deeply nested view chains found.'
        ELSE 'Deeply nested view chains detected: ' + ISNULL(@DeepViews, 'None')
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            ;WITH ViewChain AS (
                SELECT
                    referencing_id AS view_id,
                    referenced_id AS dep_id,
                    1 AS chain_depth
                FROM sys.sql_expression_dependencies sed
                INNER JOIN sys.views v ON sed.referencing_id = v.object_id
                INNER JOIN sys.views v2 ON sed.referenced_id = v2.object_id
                WHERE sed.class = 1
                UNION ALL
                SELECT
                    vc.view_id,
                    sed.referenced_id,
                    vc.chain_depth + 1
                FROM ViewChain vc
                INNER JOIN sys.sql_expression_dependencies sed ON vc.dep_id = sed.referencing_id
                INNER JOIN sys.views v2 ON sed.referenced_id = v2.object_id
                WHERE sed.class = 1
                  AND vc.chain_depth < 10
            )
            SELECT
                OBJECT_NAME(view_id) AS ViewName,
                MAX(chain_depth) AS MaxDepth
            FROM ViewChain
            GROUP BY view_id
            HAVING MAX(chain_depth) > 3
            ORDER BY MaxDepth DESC;
            ';

            TRUNCATE TABLE #DeepViews;
            INSERT INTO #DeepViews EXEC sp_executesql @Sql;

            SELECT @MaxDepth = MAX(MaxDepth), @DeepViews = STRING_AGG(ViewName + ' (depth: ' + CAST(MaxDepth AS NVARCHAR) + ')