-- Checklist: 5.2.2 Completeness: all expected sources/batches received
-- Scope: DATABASE
-- Scoring: 0=No ETL tracking evidence; 1=Staging tables exist but no batch/control metadata; 2=Control tables/batch tracking columns found (requires human validation of expected sources); 3=Not achievable automatically due to business logic dependency.
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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @ControlTables NVARCHAR(MAX) = '';
        DECLARE @BatchColumns NVARCHAR(MAX) = '';
        DECLARE @StagingTables NVARCHAR(MAX) = '';

        SELECT @ControlTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%load_log%'';

        SELECT @StagingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''%staging%'' OR t.name LIKE ''%stage%'' OR t.name LIKE ''%landing%'';

        SELECT @BatchColumns = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE c.name LIKE ''%batch%'' OR c.name LIKE ''%load_date%'' OR c.name LIKE ''%source_system%'' OR c.name LIKE ''%row_count%'';

        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = '';

        IF @ControlTables IS NOT NULL OR @BatchColumns IS NOT NULL
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''Control/Batch tracking found: '' + ISNULL(@ControlTables, ''None'') + ''; '' + ISNULL(@BatchColumns, ''None'');
        END
        ELSE IF @StagingTables IS NOT NULL
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = ''Staging tables exist but no batch/control metadata: '' + @StagingTables;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = ''No ETL staging or control artifacts found'';
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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
            DECLARE @ControlTables NVARCHAR(MAX) = '';
            DECLARE @BatchColumns NVARCHAR(MAX) = '';
            DECLARE @StagingTables NVARCHAR(MAX) = '';

            SELECT @ControlTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''%control%'' OR t.name LIKE ''%batch%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%load_log%'';

            SELECT @StagingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''%staging%'' OR t.name LIKE ''%stage%'' OR t.name LIKE ''%landing%'';

            SELECT @BatchColumns = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE c.name LIKE ''%batch%'' OR c.name LIKE ''%load_date%'' OR c.name LIKE ''%source_system%'' OR c.name LIKE ''%row_count%'';

            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '';

            IF @ControlTables IS NOT NULL OR @BatchColumns IS NOT NULL
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Control/Batch tracking found: '' + ISNULL(@ControlTables, ''None'') + ''; '' + ISNULL(@BatchColumns, ''None'');
            END
            ELSE IF @StagingTables IS NOT NULL
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Staging tables exist but no batch/control metadata: '' + @StagingTables;
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No ETL staging or control artifacts found'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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