-- Checklist: Fact table grain clearly defined and documented per fact
-- Scope: DATABASE
-- Scoring: 0: No fact tables or 0% documented. 1: >0% but <50% documented. 2: >=50% but <100% documented. 3: 100% documented.
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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalFact INT = 0;
    DECLARE @DocFact INT = 0;
    DECLARE @UndocTables NVARCHAR(MAX) = '';
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';

    SELECT @TotalFact = COUNT(*)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%'';

    SELECT @DocFact = COUNT(*)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%''
      AND EXISTS (
        SELECT 1 FROM sys.extended_properties ep
        WHERE ep.major_id = t.object_id
          AND ep.minor_id = 0
          AND ep.name IN (''MS_Description'', ''Grain'', ''Description'')
      );

    IF @TotalFact = 0
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No fact tables found in database.'';
    END
    ELSE
    BEGIN
        SELECT @UndocTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%''
          AND NOT EXISTS (
            SELECT 1 FROM sys.extended_properties ep
            WHERE ep.major_id = t.object_id
              AND ep.minor_id = 0
              AND ep.name IN (''MS_Description'', ''Grain'', ''Description'')
          );

        DECLARE @Pct FLOAT = CAST(@DocFact AS FLOAT) / @TotalFact * 100;

        IF @Pct = 100 SET @DbScore = 3;
        ELSE IF @Pct >= 50 SET @DbScore = 2;
        ELSE IF @Pct > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        SET @DbFinding = CAST(@DocFact AS NVARCHAR) + '' of '' + CAST(@TotalFact AS NVARCHAR) + '' fact tables documented. Undocumented: '' + ISNULL(@UndocTables, ''None'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            DECLARE @TotalFact INT = 0;
            DECLARE @DocFact INT = 0;
            DECLARE @UndocTables NVARCHAR(MAX) = '';
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '';

            SELECT @TotalFact = COUNT(*)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%'';

            SELECT @DocFact = COUNT(*)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%''
              AND EXISTS (
                SELECT 1 FROM sys.extended_properties ep
                WHERE ep.major_id = t.object_id
                  AND ep.minor_id = 0
                  AND ep.name IN (''MS_Description'', ''Grain'', ''Description'')
              );

            IF @TotalFact = 0
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No fact tables found in database.'';
            END
            ELSE
            BEGIN
                SELECT @UndocTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.name LIKE ''Fact%'' OR s.name LIKE ''Fact%''
                  AND NOT EXISTS (
                    SELECT 1 FROM sys.extended_properties ep
                    WHERE ep.major_id = t.object_id
                      AND ep.minor_id = 0
                      AND ep.name IN (''MS_Description'', ''Grain'', ''Description'')
                  );

                DECLARE @Pct FLOAT = CAST(@DocFact AS FLOAT) / @TotalFact * 100;

                IF @Pct = 100 SET @DbScore = 3;
                ELSE IF @Pct >= 50 SET @DbScore = 2;
                ELSE IF @Pct > 0 SET @DbScore = 1;
                ELSE SET @DbScore = 0;

                SET @DbFinding = CAST(@DocFact AS NVARCHAR) + '' of '' + CAST(@TotalFact AS NVARCHAR) + '' fact tables documented. Undocumented: '' + ISNULL(@UndocTables, ''None'');
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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