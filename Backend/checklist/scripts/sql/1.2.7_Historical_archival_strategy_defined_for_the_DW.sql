-- Checklist: Historical/archival strategy defined for the DW
-- Scope: DATABASE
-- Scoring: 0: No archival/history objects found. 1: Minimal evidence (1-3 objects). 2: Substantial proxy evidence (4+ objects). 3: Not achievable via automated proxy; requires human review of strategy documentation.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ObjCount INT = 0;
DECLARE @ObjNames NVARCHAR(MAX) = '';

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        SET @Sql = N'
        SELECT @ObjCountOut = COUNT(*), @ObjNamesOut = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name), '', '') WITHIN GROUP (ORDER BY s.name, o.name)
        FROM sys.objects o
        JOIN sys.schemas s ON o.schema_id = s.schema_id
        WHERE o.type IN (''U'', ''V'', ''P'')
          AND (
            o.name LIKE ''%archive%'' OR o.name LIKE ''%hist%'' OR o.name LIKE ''%history%'' OR o.name LIKE ''%old%'' OR o.name LIKE ''%backup%''
            OR s.name LIKE ''%archive%'' OR s.name LIKE ''%hist%'' OR s.name LIKE ''%history%'' OR s.name LIKE ''%old%'' OR s.name LIKE ''%backup%''
          );
        ';
        EXEC sp_executesql @Sql, N'@ObjCountOut INT OUTPUT, @ObjNamesOut NVARCHAR(MAX) OUTPUT', @ObjCountOut = @ObjCount OUTPUT, @ObjNamesOut = @ObjNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ObjCount = 0;
        SET @ObjNames = 'Database evaluation failed';
    END CATCH;

    IF @ObjCount = 0 SET @Score = 0;
    ELSE IF @ObjCount <= 3 SET @Score = 1;
    ELSE SET @Score = 2;

    SET @Finding = CASE WHEN @ObjCount = 0 THEN ''No archival/history objects found'' ELSE ISNULL(@ObjNames, ''No archival/history objects found'') END;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ObjCount = 0;
        SET @ObjNames = '';
        
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @ObjCountOut = COUNT(*), @ObjNamesOut = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name), '', '') WITHIN GROUP (ORDER BY s.name, o.name)
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN (''U'', ''V'', ''P'')
              AND (
                o.name LIKE ''%archive%'' OR o.name LIKE ''%hist%'' OR o.name LIKE ''%history%'' OR o.name LIKE ''%old%'' OR o.name LIKE ''%backup%''
                OR s.name LIKE ''%archive%'' OR s.name LIKE ''%hist%'' OR s.name LIKE ''%history%'' OR s.name LIKE ''%old%'' OR s.name LIKE ''%backup%''
              );
            ';
            EXEC sp_executesql @Sql, N'@ObjCountOut INT OUTPUT, @ObjNamesOut NVARCHAR(MAX) OUTPUT', @ObjCountOut = @ObjCount OUTPUT, @ObjNamesOut = @ObjNames OUTPUT;
        END TRY
        BEGIN CATCH
            SET @ObjCount = 0;
            SET @ObjNames = 'Database evaluation failed';
        END CATCH;

        IF @ObjCount = 0 SET @Score = 0;
        ELSE IF @ObjCount <= 3 SET @Score = 1;
        ELSE SET @Score = 2;

        SET @Finding = CASE WHEN @ObjCount = 0 THEN ''No archival/history objects found'' ELSE ISNULL(@ObjNames, ''No archival/history objects found'') END;
        
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);

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