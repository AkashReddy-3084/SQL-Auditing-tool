-- Checklist: Non-prod data masking/subsetting applied where sensitive
-- Scope: DATABASE
-- Scoring: 0: No masking/subsetting evidence found. 1: Partial evidence (extended properties only). 2: Dynamic Data Masking configured on some columns. 3: Comprehensive masking applied (>5 columns) or explicit subsetting configuration detected.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    
    DECLARE @MaskedCount INT = 0;
    DECLARE @PropCount INT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = N'';

    IF OBJECT_ID('sys.masked_columns') IS NOT NULL
    BEGIN
        SELECT @MaskedCount = COUNT(*) FROM sys.masked_columns;
    END

    SELECT @PropCount = COUNT(*)
    FROM sys.extended_properties ep
    JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
    JOIN sys.tables t ON c.object_id = t.object_id
    WHERE ep.name LIKE '%mask%' OR ep.name LIKE '%subset%' OR ep.name LIKE '%pii%' OR ep.name LIKE '%sensitive%';

    IF @MaskedCount > 5 SET @DbScore = 3;
    ELSE IF @MaskedCount > 0 SET @DbScore = 2;
    ELSE IF @PropCount > 0 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    SET @DbFinding = CASE
        WHEN @DbScore = 3 THEN N'Dynamic Data Masking applied to ' + CAST(@MaskedCount AS NVARCHAR) + N' columns. Comprehensive coverage detected.'
        WHEN @DbScore = 2 THEN N'Dynamic Data Masking applied to ' + CAST(@MaskedCount AS NVARCHAR) + N' columns.'
        WHEN @DbScore = 1 THEN N'Masking/subsetting intent indicated via extended properties (' + CAST(@PropCount AS NVARCHAR) + N' found), but no active Dynamic Data Masking.'
        ELSE N'No data masking or subsetting configuration detected.'
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @DbFinding);
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
DECLARE @MaskedCount INT = 0;
DECLARE @PropCount INT = 0;
DECLARE @DbScore INT = 0;
DECLARE @DbFinding NVARCHAR(MAX) = N'''';

IF OBJECT_ID(''sys.masked_columns'') IS NOT NULL
BEGIN
    SELECT @MaskedCount = COUNT(*) FROM sys.masked_columns;
END

SELECT @PropCount = COUNT(*)
FROM sys.extended_properties ep
JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
JOIN sys.tables t ON c.object_id = t.object_id
WHERE ep.name LIKE ''%mask%'' OR ep.name LIKE ''%subset%'' OR ep.name LIKE ''%pii%'' OR ep.name LIKE ''%sensitive%'';

IF @MaskedCount > 5 SET @DbScore = 3;
ELSE IF @MaskedCount > 0 SET @DbScore = 2;
ELSE IF @PropCount > 0 SET @DbScore = 1;
ELSE SET @DbScore = 0;

SET @DbFinding = CASE
    WHEN @DbScore = 3 THEN N''Dynamic Data Masking applied to '' + CAST(@MaskedCount AS NVARCHAR) + N'' columns. Comprehensive coverage detected.''
    WHEN @DbScore = 2 THEN N''Dynamic Data Masking applied to '' + CAST(@MaskedCount AS NVARCHAR) + N'' columns.''
    WHEN @DbScore = 1 THEN N''Masking/subsetting intent indicated via extended properties ('' + CAST(@PropCount AS NVARCHAR) + N'' found), but no active Dynamic Data Masking.''
    ELSE N''No data masking or subsetting configuration detected.''
END;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';

            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;