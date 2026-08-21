-- Checklist: Solution maintainable by someone other than the original builder
-- Scope: DATABASE
-- Scoring: 0: <10% objects documented/commented. 1: 10-39% documented/commented. 2: 40-79% documented/commented or partial structure. 3: >=80% documented/commented with clear schema separation. (Automated proxy check capped at 2; full compliance requires human review.)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @ObjCount INT, @DocCount INT, @CommentCount INT, @SchemaCount INT, @Coverage DECIMAL(5,2);
    SELECT @ObjCount = COUNT(*) FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;
    SELECT @DocCount = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND major_id IN (SELECT object_id FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0);
    SELECT @CommentCount = COUNT(*) FROM sys.sql_modules WHERE object_id IN (SELECT object_id FROM sys.objects WHERE type IN (''P'',''FN'',''IF'',''TF'',''TR'',''V'') AND is_ms_shipped = 0) AND (definition LIKE ''%--%'' OR definition LIKE ''%/*%'');
    SELECT @SchemaCount = COUNT(*) FROM sys.schemas WHERE is_ms_shipped = 0 AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'');
    SET @Coverage = CASE WHEN @ObjCount > 0 THEN CAST((@DocCount + @CommentCount) AS DECIMAL(5,2)) / @ObjCount ELSE 0 END;
    DECLARE @DbScore INT;
    IF @Coverage >= 0.80 AND @SchemaCount >= 2 SET @DbScore = 2;
    ELSE IF @Coverage >= 0.40 OR @SchemaCount >= 2 SET @DbScore = 2;
    ELSE IF @Coverage >= 0.10 SET @DbScore = 1;
    ELSE SET @DbScore = 0;
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, ''Objects: '' + CAST(@ObjCount AS NVARCHAR) + '', Documented: '' + CAST(@DocCount AS NVARCHAR) + '', Commented: '' + CAST(@CommentCount AS NVARCHAR) + '', Coverage: '' + CAST(@Coverage * 100 AS NVARCHAR) + ''%, User Schemas: '' + CAST(@SchemaCount AS NVARCHAR));
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @ObjCount INT, @DocCount INT, @CommentCount INT, @SchemaCount INT, @Coverage DECIMAL(5,2);
            SELECT @ObjCount = COUNT(*) FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;
            SELECT @DocCount = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND major_id IN (SELECT object_id FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0);
            SELECT @CommentCount = COUNT(*) FROM sys.sql_modules WHERE object_id IN (SELECT object_id FROM sys.objects WHERE type IN (''P'',''FN'',''IF'',''TF'',''TR'',''V'') AND is_ms_shipped = 0) AND (definition LIKE ''%--%'' OR definition LIKE ''%/*%'');
            SELECT @SchemaCount = COUNT(*) FROM sys.schemas WHERE is_ms_shipped = 0 AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'');
            SET @Coverage = CASE WHEN @ObjCount > 0 THEN CAST((@DocCount + @CommentCount) AS DECIMAL(5,2)) / @ObjCount ELSE 0 END;
            DECLARE @DbScore INT;
            IF @Coverage >= 0.80 AND @SchemaCount >= 2 SET @DbScore = 2;
            ELSE IF @Coverage >= 0.40 OR @SchemaCount >= 2 SET @DbScore = 2;
            ELSE IF @Coverage >= 0.10 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, ''Objects: '' + CAST(@ObjCount AS NVARCHAR) + '', Documented: '' + CAST(@DocCount AS NVARCHAR) + '', Commented: '' + CAST(@CommentCount AS NVARCHAR) + '', Coverage: '' + CAST(@Coverage * 100 AS NVARCHAR) + ''%, User Schemas: '' + CAST(@SchemaCount AS NVARCHAR));
            ';
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