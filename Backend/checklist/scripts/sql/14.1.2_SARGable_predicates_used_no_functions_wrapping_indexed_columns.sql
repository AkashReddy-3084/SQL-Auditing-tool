-- Checklist: SARGable predicates used (no functions wrapping indexed columns)
-- Scope: DATABASE
-- Scoring: 3: No non-SARGable patterns detected. 2: 1-4 patterns detected. 1: 5-15 patterns detected. 0: >15 patterns detected.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @MatchCount INT;
DECLARE @TopObjects NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SELECT @MatchCount = COUNT(*),
           @TopObjects = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)), N'','')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''V'', ''IF'', ''TF'')
      AND (
          m.definition LIKE ''%WHERE%+%''
          OR m.definition LIKE ''%WHERE%-%''
          OR m.definition LIKE ''%WHERE%*%''
          OR m.definition LIKE ''%WHERE%/%''
          OR m.definition LIKE ''%WHERE%YEAR(%''
          OR m.definition LIKE ''%WHERE%MONTH(%''
          OR m.definition LIKE ''%WHERE%DAY(%''
          OR m.definition LIKE ''%WHERE%LEFT(%''
          OR m.definition LIKE ''%WHERE%RIGHT(%''
          OR m.definition LIKE ''%WHERE%CAST(%''
          OR m.definition LIKE ''%WHERE%CONVERT(%''
          OR m.definition LIKE ''%WHERE%ISNULL(%''
          OR m.definition LIKE ''%WHERE%COALESCE(%''
          OR m.definition LIKE ''%WHERE%LEN(%''
          OR m.definition LIKE ''%WHERE%REPLACE(%''
          OR m.definition LIKE ''%WHERE%SUBSTRING(%''
          OR m.definition LIKE ''%WHERE%UPPER(%''
          OR m.definition LIKE ''%WHERE%LOWER(%''
          OR m.definition LIKE ''%WHERE%TRIM(%''
      );
    ';
    EXEC sp_executesql @Sql, N'@MatchCount INT OUTPUT, @TopObjects NVARCHAR(MAX) OUTPUT', @MatchCount OUTPUT, @TopObjects OUTPUT;

    SET @Score = CASE WHEN @MatchCount = 0 THEN 3 WHEN @MatchCount BETWEEN 1 AND 4 THEN 2 WHEN @MatchCount BETWEEN 5 AND 15 THEN 1 ELSE 0 END;
    SET @Finding = CASE WHEN @MatchCount = 0 THEN ''No non-SARGable predicates found.'' ELSE CAST(@MatchCount AS NVARCHAR) + '' non-SARGable patterns detected. Examples: '' + ISNULL(@TopObjects, ''N/A'') END;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
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
            SELECT @MatchCount = COUNT(*),
                   @TopObjects = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)), N'','')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''V'', ''IF'', ''TF'')
              AND (
                  m.definition LIKE ''%WHERE%+%''
                  OR m.definition LIKE ''%WHERE%-%''
                  OR m.definition LIKE ''%WHERE%*%''
                  OR m.definition LIKE ''%WHERE%/%''
                  OR m.definition LIKE ''%WHERE%YEAR(%''
                  OR m.definition LIKE ''%WHERE%MONTH(%''
                  OR m.definition LIKE ''%WHERE%DAY(%''
                  OR m.definition LIKE ''%WHERE%LEFT(%''
                  OR m.definition LIKE ''%WHERE%RIGHT(%''
                  OR m.definition LIKE ''%WHERE%CAST(%''
                  OR m.definition LIKE ''%WHERE%CONVERT(%''
                  OR m.definition LIKE ''%WHERE%ISNULL(%''
                  OR m.definition LIKE ''%WHERE%COALESCE(%''
                  OR m.definition LIKE ''%WHERE%LEN(%''
                  OR m.definition LIKE ''%WHERE%REPLACE(%''
                  OR m.definition LIKE ''%WHERE%SUBSTRING(%''
                  OR m.definition LIKE ''%WHERE%UPPER(%''
                  OR m.definition LIKE ''%WHERE%LOWER(%''
                  OR m.definition LIKE ''%WHERE%TRIM(%''
              );
            ';
            EXEC sp_executesql @Sql, N'@MatchCount INT OUTPUT, @TopObjects NVARCHAR(MAX) OUTPUT', @MatchCount OUTPUT, @TopObjects OUTPUT;

            SET @Score = CASE WHEN @MatchCount = 0 THEN 3 WHEN @MatchCount BETWEEN 1 AND 4 THEN 2 WHEN @MatchCount BETWEEN 5 AND 15 THEN 1 ELSE 0 END;
            SET @Finding = CASE WHEN @MatchCount = 0 THEN ''No non-SARGable predicates found.'' ELSE CAST(@MatchCount AS NVARCHAR) + '' non-SARGable patterns detected. Examples: '' + ISNULL(@TopObjects, ''N/A'') END;

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
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
          AND Finding <>