-- Checklist: Dependencies documented (linked servers, cross-database references)
-- Scope: DATABASE
-- Scoring: 3 = no dependencies found (N/A) or 50%+ of referencing objects have a documentation tag; 2 = under 50% do; 1 = dependencies exist but none documented; 0 = evaluation could not run

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @DependencyCount INT, @DocumentedDependencyCount INT;

    SELECT @DependencyCount = COUNT(DISTINCT d.referencing_id)
    FROM sys.sql_expression_dependencies d
    WHERE d.referenced_database_name IS NOT NULL AND d.referenced_database_name <> DB_NAME();

    SELECT @DocumentedDependencyCount = COUNT(DISTINCT d.referencing_id)
    FROM sys.sql_expression_dependencies d
    WHERE d.referenced_database_name IS NOT NULL AND d.referenced_database_name <> DB_NAME()
      AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = d.referencing_id AND ep.minor_id = 0 AND ep.name = 'MS_Description');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@DependencyCount,0) = 0 THEN 3
             WHEN ISNULL(@DocumentedDependencyCount,0) = 0 THEN 1
             WHEN (CAST(ISNULL(@DocumentedDependencyCount,0) AS DECIMAL(9,4)) / NULLIF(@DependencyCount,0)) >= 0.50 THEN 3
             ELSE 2 END,
        CASE WHEN ISNULL(@DependencyCount,0) = 0 THEN 'No cross-database dependencies found - not applicable'
             ELSE CONCAT('Objects with cross-database references = ', @DependencyCount, ', with a documentation tag = ', ISNULL(@DocumentedDependencyCount,0)) END
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @dc INT, @doc INT;
SELECT @dc = COUNT(DISTINCT d.referencing_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies d
WHERE d.referenced_database_name IS NOT NULL AND d.referenced_database_name <> @p_Db;
SELECT @doc = COUNT(DISTINCT d.referencing_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies d
WHERE d.referenced_database_name IS NOT NULL AND d.referenced_database_name <> @p_Db
  AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.extended_properties ep WHERE ep.major_id = d.referencing_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'');
SELECT @p_Db,
       CASE WHEN ISNULL(@dc,0) = 0 THEN 3
            WHEN ISNULL(@doc,0) = 0 THEN 1
            WHEN (CAST(ISNULL(@doc,0) AS DECIMAL(9,4)) / NULLIF(@dc,0)) >= 0.50 THEN 3
            ELSE 2 END,
       CASE WHEN ISNULL(@dc,0) = 0 THEN ''No cross-database dependencies found - not applicable''
            ELSE CONCAT(''Objects with cross-database references = '', @dc, '', with a documentation tag = '', ISNULL(@doc,0)) END;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;