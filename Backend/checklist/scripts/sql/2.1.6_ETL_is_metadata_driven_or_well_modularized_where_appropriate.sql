-- Checklist: ETL is metadata-driven or well-modularized where appropriate
-- Scope: DATABASE
-- Scoring: 0=No ETL procs or completely monolithic/hardcoded; 1=ETL procs exist but largely monolithic with minimal modularity/metadata; 2=Clear evidence of modularity (high reuse) or metadata-driven patterns (config/control table refs); 3=Strong evidence of both (capped at 2 in execution due to proxy nature).
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TotalProcs INT = 0;
        DECLARE @MetaProcs INT = 0;
        DECLARE @ModularProcs INT = 0;

        SELECT @TotalProcs = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0;

        CREATE TABLE #ConfigTables (object_id INT);
        INSERT INTO #ConfigTables
        SELECT object_id FROM sys.tables
        WHERE name LIKE ''%config%'' OR name LIKE ''%control%'' OR name LIKE ''%metadata%'' OR name LIKE ''%etl%'' OR name LIKE ''%batch%'' OR name LIKE ''%load%'';

        SELECT @MetaProcs = COUNT(DISTINCT referencing_id)
        FROM sys.sql_expression_dependencies
        WHERE class = 1 AND referenced_id IS NOT NULL
        AND referenced_id IN (SELECT object_id FROM #ConfigTables)
        AND referencing_id IN (SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0);

        SELECT @ModularProcs = COUNT(*)
        FROM (
            SELECT referencing_id
            FROM sys.sql_expression_dependencies
            WHERE class = 1 AND referenced_id IS NOT NULL
            AND referenced_id IN (SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0)
            GROUP BY referencing_id
            HAVING COUNT(*) >= 3
        ) AS Modular;

        DECLARE @DbScore INT = 0;
        IF @TotalProcs = 0
            SET @DbScore = 0;
        ELSE IF @MetaProcs > 0 AND @ModularProcs > 0
            SET @DbScore = 3;
        ELSE IF @MetaProcs > 0 OR @ModularProcs > 0
            SET @DbScore = 2;
        ELSE
            SET @DbScore = 1;

        -- Cap at 2 due to proxy/indirect evidence nature
        IF @DbScore > 2 SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore);
        DROP TABLE #ConfigTables;
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;