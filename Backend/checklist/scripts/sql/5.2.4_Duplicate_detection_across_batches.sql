SET NOCOUNT ON;

-- Checklist: Duplicate detection across batches
-- Scope: DATABASE
-- Scoring: 0=No staging tables/ETL artifacts found; 1=Staging tables exist but lack unique constraints and explicit duplicate detection logic; 2=ETL procedures contain duplicate detection logic but staging tables lack unique constraints; 3=Staging tables have unique constraints/indexes on business keys, or ETL procedures explicitly implement robust duplicate detection across batches.

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
    -- Azure SQL Database: Evaluate only current database
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @StagingCount INT = 0;
    DECLARE @UniqueCount INT = 0;
    DECLARE @ProcCount INT = 0;
    DECLARE @StagingTables NVARCHAR(MAX) = '''';
    DECLARE @UniqueTables NVARCHAR(MAX) = '''';
    DECLARE @DupProcs NVARCHAR(MAX) = '''';
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @StagingCount = COUNT(1),
           @StagingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
    FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name IN (''stg'',''staging'',''landing'',''raw'') OR t.name LIKE ''stg%'' OR t.name LIKE ''staging%'';

    IF @StagingCount > 0
    BEGIN
        SELECT @UniqueCount = COUNT(1),
               @UniqueTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.indexes i ON i.object_id = t.object_id AND i.is_unique = 1
        WHERE s.name IN (''stg'',''staging'',''landing'',''raw'') OR t.name LIKE ''stg%'' OR t.name LIKE ''staging%'';

        SELECT @ProcCount = COUNT(1),
               @DupProcs = STRING_AGG(p.name, '', '')
        FROM sys.procedures p JOIN sys.sql_modules m ON m.object_id = p.object_id
        WHERE m.definition LIKE ''%duplicate%'' OR m.definition LIKE ''%batch%'' OR m.definition LIKE ''%ROW_NUMBER%'' OR m.definition LIKE ''%GROUP BY%'';
    END

    IF @StagingCount = 0
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No staging tables or ETL artifacts found'';
    END
    ELSE IF @UniqueCount > 0 OR @ProcCount > 0
    BEGIN
        SET @DbScore = CASE WHEN @UniqueCount > 0 THEN 3 ELSE 2 END;
        SET @DbFinding = ''Staging tables: '' + @StagingTables + ''; Unique constraints: '' + ISNULL(@UniqueTables, ''None'') + ''; Duplicate detection procs: '' + ISNULL(@DupProcs, ''None'');
    END
    ELSE
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''Staging tables found ('' + @StagingTables + '') but lack unique constraints and explicit duplicate detection logic'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
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
            DECLARE @StagingCount INT = 0;
            DECLARE @UniqueCount INT = 0;
            DECLARE @ProcCount INT = 0;
            DECLARE @StagingTables NVARCHAR(MAX) = '''';
            DECLARE @UniqueTables NVARCHAR(MAX) = '''';
            DECLARE @DupProcs NVARCHAR(MAX) = '''';
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @StagingCount = COUNT(1),
                   @StagingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name IN (''stg'',''staging'',''landing'',''raw'') OR t.name LIKE ''stg%'' OR t.name LIKE ''staging%'';

            IF @StagingCount > 0
            BEGIN
                SELECT @UniqueCount = COUNT(1),
                       @UniqueTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
                FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
                JOIN sys.indexes i ON i.object_id = t.object_id AND i.is_unique = 1
                WHERE s.name IN (''stg'',''staging'',''landing'',''raw'') OR t.name LIKE ''stg%'' OR t.name LIKE ''staging%'';

                SELECT @ProcCount = COUNT(1),
                       @DupProcs = STRING_AGG(p.name, '', '')
                FROM sys.procedures p JOIN sys.sql_modules m ON m.object_id = p.object_id
                WHERE m.definition LIKE ''%duplicate%'' OR m.definition LIKE ''%batch%'' OR m.definition LIKE ''%ROW_NUMBER%'' OR m.definition LIKE ''%GROUP BY%'';
            END

            IF @StagingCount = 0
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No staging tables or ETL artifacts found'';
            END
            ELSE IF @UniqueCount > 0 OR @ProcCount > 0
            BEGIN
                SET @DbScore = CASE WHEN @UniqueCount > 0 THEN 3 ELSE 2 END;
                SET @DbFinding = ''Staging tables: '' + @StagingTables + ''; Unique constraints: '' + ISNULL(@UniqueTables, ''None'') + ''; Duplicate detection procs: '' + ISNULL(@DupProcs, ''None'');
            END
            ELSE
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Staging tables found ('' + @StagingTables + '') but lack unique constraints and explicit duplicate detection logic'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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

    SET @DatabaseQueried = (
        SELECT STRING_AGG(DbName, ', ')
        FROM #DbResults
    );
END

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