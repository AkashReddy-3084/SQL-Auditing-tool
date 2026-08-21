-- Checklist: Data retention policies defined per data category
-- Scope: DATABASE
-- Scoring: 0=No retention/category metadata found; 1=Metadata on <50% of tables; 2=Metadata on 50-89% of tables; 3=Metadata on >=90% of tables.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

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
    DECLARE @TotalTables INT;
    DECLARE @CoveredTables INT;
    DECLARE @MissingTables NVARCHAR(MAX);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

    SELECT @CoveredTables = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
    WHERE t.is_ms_shipped = 0
      AND (ep.name LIKE ''%retention%'' OR ep.name LIKE ''%category%'' OR ep.name LIKE ''%classification%'' OR ep.name LIKE ''%expiry%'' OR ep.name LIKE ''%ttl%'');

    SELECT @MissingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
      AND (ep.name LIKE ''%retention%'' OR ep.name LIKE ''%category%'' OR ep.name LIKE ''%classification%'' OR ep.name LIKE ''%expiry%'' OR ep.name LIKE ''%ttl%'')
    WHERE t.is_ms_shipped = 0 AND ep.major_id IS NULL;

    IF @TotalTables = 0 SET @DbScore = 3;
    ELSE IF @CoveredTables = 0 SET @DbScore = 0;
    ELSE BEGIN
        DECLARE @Coverage DECIMAL(5,2) = CAST(@CoveredTables AS DECIMAL) / @TotalTables * 100;
        IF @Coverage >= 90 SET @DbScore = 3;
        ELSE IF @Coverage >= 50 SET @DbScore = 2;
        ELSE SET @DbScore = 1;
    END

    IF @DbScore = 3 SET @DbFinding = ''All or nearly all tables have retention/category metadata defined.'';
    ELSE IF @DbScore = 2 SET @DbFinding = ''Majority of tables have metadata, but gaps remain: '' + ISNULL(@MissingTables, ''None'');
    ELSE IF @DbScore = 1 SET @DbFinding = ''Limited metadata coverage. Missing on: '' + ISNULL(@MissingTables, ''None'');
    ELSE SET @DbFinding = ''No retention or category metadata found on any tables.'';

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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
            DECLARE @TotalTables INT;
            DECLARE @CoveredTables INT;
            DECLARE @MissingTables NVARCHAR(MAX);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

            SELECT @CoveredTables = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE t.is_ms_shipped = 0
              AND (ep.name LIKE ''%retention%'' OR ep.name LIKE ''%category%'' OR ep.name LIKE ''%classification%'' OR ep.name LIKE ''%expiry%'' OR ep.name LIKE ''%ttl%'');

            SELECT @MissingTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
              AND (ep.name LIKE ''%retention%'' OR ep.name LIKE ''%category%'' OR ep.name LIKE ''%classification%'' OR ep.name LIKE ''%expiry%'' OR ep.name LIKE ''%ttl%'')
            WHERE t.is_ms_shipped = 0 AND ep.major_id IS NULL;

            IF @TotalTables = 0 SET @DbScore = 3;
            ELSE IF @CoveredTables = 0 SET @DbScore = 0;
            ELSE BEGIN
                DECLARE @Coverage DECIMAL(5,2) = CAST(@CoveredTables AS DECIMAL) / @TotalTables * 100;
                IF @Coverage >= 90 SET @DbScore = 3;
                ELSE IF @Coverage >= 50 SET @DbScore = 2;
                ELSE SET @DbScore = 1;
            END

            IF @DbScore = 3 SET @DbFinding = ''All or nearly all tables have retention/category metadata defined.'';
            ELSE IF @DbScore = 2 SET @DbFinding = ''Majority of tables have metadata, but gaps remain: '' + ISNULL(@MissingTables, ''None'');
            ELSE IF @DbScore = 1 SET @DbFinding = ''Limited metadata coverage. Missing on: '' + ISNULL(@MissingTables, ''None'');
            ELSE SET @DbFinding = ''No retention or category metadata found on any tables.'';

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