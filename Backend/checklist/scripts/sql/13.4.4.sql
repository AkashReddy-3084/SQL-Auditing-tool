-- Checklist: Code is self-documenting or well-commented for complex logic
-- Scope: DATABASE
-- Scoring: 3 = 75%+ of structurally complex procedures contain a comment marker; 2 = 25-74%; 1 = under 25%; 0 = no structurally complex procedures found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @ComplexProcCount INT, @CommentedComplexProcCount INT;

    SELECT @ComplexProcCount = COUNT(DISTINCT p.object_id)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON m.object_id = p.object_id
    WHERE m.definition LIKE '%CURSOR %' OR m.definition LIKE '%MERGE %';

    SELECT @CommentedComplexProcCount = COUNT(DISTINCT p.object_id)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON m.object_id = p.object_id
    WHERE (m.definition LIKE '%CURSOR %' OR m.definition LIKE '%MERGE %')
      AND (m.definition LIKE '%--%' OR m.definition LIKE '%/*%');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@ComplexProcCount,0) = 0 THEN 0
             WHEN (CAST(ISNULL(@CommentedComplexProcCount,0) AS DECIMAL(9,4)) / NULLIF(@ComplexProcCount,0)) >= 0.75 THEN 3
             WHEN (CAST(ISNULL(@CommentedComplexProcCount,0) AS DECIMAL(9,4)) / NULLIF(@ComplexProcCount,0)) >= 0.25 THEN 2
             ELSE 1 END,
        CONCAT('Structurally complex procedures = ', ISNULL(@ComplexProcCount,0), ', with a comment marker = ', ISNULL(@CommentedComplexProcCount,0))
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
            SET @Sql = N'DECLARE @cc INT, @kc INT;
SELECT @cc = COUNT(DISTINCT p.object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON m.object_id = p.object_id
WHERE m.definition LIKE ''%CURSOR %'' OR m.definition LIKE ''%MERGE %'';
SELECT @kc = COUNT(DISTINCT p.object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON m.object_id = p.object_id
WHERE (m.definition LIKE ''%CURSOR %'' OR m.definition LIKE ''%MERGE %'')
  AND (m.definition LIKE ''%--%'' OR m.definition LIKE ''%/*%'');
SELECT @p_Db,
       CASE WHEN ISNULL(@cc,0) = 0 THEN 0
            WHEN (CAST(ISNULL(@kc,0) AS DECIMAL(9,4)) / NULLIF(@cc,0)) >= 0.75 THEN 3
            WHEN (CAST(ISNULL(@kc,0) AS DECIMAL(9,4)) / NULLIF(@cc,0)) >= 0.25 THEN 2
            ELSE 1 END,
       CONCAT(''Structurally complex procedures = '', ISNULL(@cc,0), '', with a comment marker = '', ISNULL(@kc,0));';

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