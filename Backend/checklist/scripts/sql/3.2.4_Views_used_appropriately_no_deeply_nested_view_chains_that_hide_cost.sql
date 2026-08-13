-- Checklist: Views used appropriately (no deeply nested view chains that hide cost)
-- Scope: DATABASE
-- Scoring: 0=Max depth >=5 (Fail), 1=Max depth 4 (Partial Pass), 2=Max depth 3 (Mostly Pass), 3=Max depth <=2 or no views (Pass)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @MaxDepth INT;
        WITH ViewChain AS (
            SELECT
                sed.referencing_id,
                sed.referenced_id,
                1 AS depth
            FROM sys.sql_expression_dependencies sed
            INNER JOIN sys.objects o_ref ON sed.referencing_id = o_ref.object_id
            INNER JOIN sys.objects o_refd ON sed.referenced_id = o_refd.object_id
            WHERE sed.class = 1
              AND sed.is_ambiguous = 0
              AND o_ref.type = ''V''
              AND o_refd.type = ''V''
              AND o_ref.is_ms_shipped = 0

            UNION ALL

            SELECT
                vc.referencing_id,
                sed.referenced_id,
                vc.depth + 1
            FROM ViewChain vc
            INNER JOIN sys.sql_expression_dependencies sed ON vc.referenced_id = sed.referencing_id
            INNER JOIN sys.objects o_refd ON sed.referenced_id = o_refd.object_id
            WHERE sed.class = 1
              AND sed.is_ambiguous = 0
              AND o_refd.type = ''V''
              AND o_refd.is_ms_shipped = 0
              AND vc.depth < 10
        )
        SELECT @MaxDepth = ISNULL(MAX(depth), 0) FROM ViewChain;

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (@DbName, CASE
            WHEN @MaxDepth >= 5 THEN 0
            WHEN @MaxDepth = 4 THEN 1
            WHEN @MaxDepth = 3 THEN 2
            ELSE 3
        END);
        ';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 3);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;