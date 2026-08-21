-- Checklist: Data flow / source-to-target mappings documented
-- Scope: DATABASE
-- Scoring: 0=No documentation found; 1=Minimal documentation (<=10% objects); 2=Partial documentation (10-79% objects); 3=Comprehensive documentation (>=80% objects). NOTE: This script provides automated evidence. Full compliance requires human review.

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalObjects INT;
    DECLARE @DocumentedObjects INT;
    DECLARE @Pct FLOAT;
    DECLARE @DbScore INT;
    DECLARE @Finding NVARCHAR(MAX);

    SELECT @TotalObjects = COUNT(*) FROM sys.tables WHERE type = ''U'';
    SELECT @DocumentedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties 
    WHERE class = 1 AND (name LIKE ''%[Ss]ource%'' OR name LIKE ''%[Tt]arget%'' OR name LIKE ''%[Mm]apping%'' OR name LIKE ''%[Dd]escription%'' OR name LIKE ''%[Ff]low%'');

    SET @Pct = CASE WHEN @TotalObjects > 0 THEN (@DocumentedObjects * 100.0 / @TotalObjects) ELSE 0 END;

    SET @DbScore = CASE 
        WHEN @Pct >= 80 THEN 3
        WHEN @Pct > 10 THEN 2
        WHEN @Pct > 0 THEN 1
        ELSE 0 
    END;

    SET @Finding = CASE 
        WHEN @DbScore >= 2 THEN ''Compliant: '' + CAST(@DocumentedObjects AS NVARCHAR) + '' / '' + CAST(@TotalObjects AS NVARCHAR) + '' objects documented ('' + CAST(ROUND(@Pct, 1) AS NVARCHAR) + ''%)''
        ELSE ''Non-compliant: '' + CAST(@TotalObjects - @DocumentedObjects AS NVARCHAR) + '' / '' + CAST(@TotalObjects AS NVARCHAR) + '' objects lack mapping documentation ('' + CAST(ROUND(@Pct, 1) AS NVARCHAR) + ''%)''
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql;
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
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalObjects INT;
            DECLARE @DocumentedObjects INT;
            DECLARE @Pct FLOAT;
            DECLARE @DbScore INT;
            DECLARE @Finding NVARCHAR(MAX);

            SELECT @TotalObjects = COUNT(*) FROM sys.tables WHERE type = ''U'';
            SELECT @DocumentedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties 
            WHERE class = 1 AND (name LIKE ''%[Ss]ource%'' OR name LIKE ''%[Tt]arget%'' OR name LIKE ''%[Mm]apping%'' OR name LIKE ''%[Dd]escription%'' OR name LIKE ''%[Ff]low%'');

            SET @Pct = CASE WHEN @TotalObjects > 0 THEN (@DocumentedObjects * 100.0 / @TotalObjects) ELSE 0 END;

            SET @DbScore = CASE 
                WHEN @Pct >= 80 THEN 3
                WHEN @Pct > 10 THEN 2
                WHEN @Pct > 0 THEN 1
                ELSE 0 
            END;

            SET @Finding = CASE 
                WHEN @DbScore >= 2 THEN ''Compliant: '' + CAST(@DocumentedObjects AS NVARCHAR) + '' / '' + CAST(@TotalObjects AS NVARCHAR) + '' objects documented ('' + CAST(ROUND(@Pct, 1) AS NVARCHAR) + ''%)''
                ELSE ''Non-compliant: '' + CAST(@TotalObjects - @DocumentedObjects AS NVARCHAR) + '' / '' + CAST(@TotalObjects AS NVARCHAR) + '' objects lack mapping documentation ('' + CAST(ROUND(@Pct, 1) AS NVARCHAR) + ''%)''
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @Finding);
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'No user databases found');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;