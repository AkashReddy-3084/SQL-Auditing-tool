-- Checklist: String / Text: encoding/collation consistent; max length respected; no silent truncation
-- Scope: DATABASE
-- Scoring: 3: 0 non-compliant columns; 2: 1-5; 1: 6-20; 0: >20. Non-compliant = collation differs from DB default, or max_length <= 0 (varchar(max)/text/ntext).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    SET @DbName = DB_NAME();
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
    DECLARE @DbCollation NVARCHAR(128) = DATABASEPROPERTYEX(DB_ID(), ''Collation'');
    DECLARE @NonCompliantCount INT = 0;
    DECLARE @NonCompliantList NVARCHAR(MAX) = '''';

    SELECT @NonCompliantCount = COUNT(*),
           @NonCompliantList = ISNULL(STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', ''), '''')
    FROM sys.columns c
    JOIN sys.types tp ON c.user_type_id = tp.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE tp.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
      AND (c.max_length <= 0 OR c.collation_name <> @DbCollation);

    DECLARE @DbScore INT;
    IF @NonCompliantCount = 0 SET @DbScore = 3;
    ELSE IF @NonCompliantCount <= 5 SET @DbScore = 2;
    ELSE IF @NonCompliantCount <= 20 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    DECLARE @DbFinding NVARCHAR(MAX);
    IF @NonCompliantCount = 0
        SET @DbFinding = ''All string columns comply with collation and max length rules.'';
    ELSE
        SET @DbFinding = CAST(@NonCompliantCount AS NVARCHAR(10)) + '' non-compliant columns: '' + @NonCompliantList;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @DbFinding);';

    EXEC sp_executesql @Sql, N'@DbName NVARCHAR(128)', @DbName = @DbName;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @DbCollation NVARCHAR(128) = DATABASEPROPERTYEX(DB_ID(), ''Collation'');
            DECLARE @NonCompliantCount INT = 0;
            DECLARE @NonCompliantList NVARCHAR(MAX) = '''';

            SELECT @NonCompliantCount = COUNT(*),
                   @NonCompliantList = ISNULL(STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', ''), '''')
            FROM sys.columns c
            JOIN sys.types tp ON c.user_type_id = tp.user_type_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE tp.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
              AND (c.max_length <= 0 OR c.collation_name <> @DbCollation);

            DECLARE @DbScore INT;
            IF @NonCompliantCount = 0 SET @DbScore = 3;
            ELSE IF @NonCompliantCount <= 5 SET @DbScore = 2;
            ELSE IF @NonCompliantCount <= 20 SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            DECLARE @DbFinding NVARCHAR(MAX);
            IF @NonCompliantCount = 0
                SET @DbFinding = ''All string columns comply with collation and max length rules.'';
            ELSE
                SET @DbFinding = CAST(@NonCompliantCount AS NVARCHAR(10)) + '' non-compliant columns: '' + @NonCompliantList;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, @DbScore, @DbFinding);';

            EXEC sp_executesql @Sql, N'@DbName NVARCHAR(128)', @DbName = @DbName;
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL((
    SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
    FROM #DbResults
    WHERE Finding IS NOT NULL AND Finding <> ''
), 'No non-compliant findings found');

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;