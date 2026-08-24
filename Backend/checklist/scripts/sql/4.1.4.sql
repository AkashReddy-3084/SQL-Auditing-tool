-- Checklist: No stringly-typed dates/numbers; correct temporal types
-- Scope: DATABASE
-- Scoring: 3 = 0% of date/numeric-named columns are character-typed; 2 = under 25%; 1 = 25%+; 0 = no date/numeric-named columns found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @NamedColumnCount INT, @StringlyTypedCount INT;

    SELECT @NamedColumnCount = COUNT(*)
    FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE c.name LIKE '%date%' OR c.name LIKE '%amount%' OR c.name LIKE '%price%' OR c.name LIKE '%qty%' OR c.name LIKE '%quantity%' OR c.name LIKE '%total%';

    SELECT @StringlyTypedCount = COUNT(*)
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE (c.name LIKE '%date%' OR c.name LIKE '%amount%' OR c.name LIKE '%price%' OR c.name LIKE '%qty%' OR c.name LIKE '%quantity%' OR c.name LIKE '%total%')
      AND ty.name IN ('varchar','nvarchar','char','nchar');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@NamedColumnCount,0) = 0 THEN 0
             WHEN (CAST(ISNULL(@StringlyTypedCount,0) AS DECIMAL(9,4)) / NULLIF(@NamedColumnCount,0)) >= 0.25 THEN 1
             WHEN ISNULL(@StringlyTypedCount,0) > 0 THEN 2
             ELSE 3 END,
        CONCAT('Date/numeric-named columns = ', ISNULL(@NamedColumnCount,0), ', character-typed = ', ISNULL(@StringlyTypedCount,0))
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
            SET @Sql = N'DECLARE @nc INT, @sc INT;
SELECT @nc = COUNT(*)
FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON t.object_id = c.object_id
WHERE c.name LIKE ''%date%'' OR c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%qty%'' OR c.name LIKE ''%quantity%'' OR c.name LIKE ''%total%'';
SELECT @sc = COUNT(*)
FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON t.object_id = c.object_id
WHERE (c.name LIKE ''%date%'' OR c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%qty%'' OR c.name LIKE ''%quantity%'' OR c.name LIKE ''%total%'')
  AND ty.name IN (''varchar'',''nvarchar'',''char'',''nchar'');
SELECT @p_Db,
       CASE WHEN ISNULL(@nc,0) = 0 THEN 0
            WHEN (CAST(ISNULL(@sc,0) AS DECIMAL(9,4)) / NULLIF(@nc,0)) >= 0.25 THEN 1
            WHEN ISNULL(@sc,0) > 0 THEN 2
            ELSE 3 END,
       CONCAT(''Date/numeric-named columns = '', ISNULL(@nc,0), '', character-typed = '', ISNULL(@sc,0));';

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