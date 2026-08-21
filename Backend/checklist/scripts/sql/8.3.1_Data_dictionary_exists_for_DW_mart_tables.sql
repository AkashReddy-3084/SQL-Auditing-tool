-- Checklist: Data dictionary exists for DW/mart tables
-- Scope: DATABASE
-- Scoring: 3: >=90% tables have descriptions or dedicated dictionary table exists. 2: >=50% have descriptions. 1: >=10% have descriptions. 0: <10% or none.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current DB only
    SET @DatabaseQueried = DB_NAME();
    
    DECLARE @TotalTables INT;
    DECLARE @DescTables INT;
    DECLARE @DictTableExists BIT = 0;

    SELECT @TotalTables = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.is_ms_shipped = 0;
    SELECT @DescTables = COUNT(DISTINCT t.object_id) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1 AND ep.minor_id = 0 AND ep.name = 'MS_Description' WHERE t.is_ms_shipped = 0;
    SELECT @DictTableExists = CASE WHEN EXISTS(SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name LIKE '%DataDictionary%' OR t.name LIKE '%Metadata%' OR t.name LIKE '%Dictionary%') THEN 1 ELSE 0 END;

    IF @TotalTables = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No user tables found; check not applicable.';
    END
    ELSE IF @DictTableExists = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Dedicated dictionary/metadata table found.';
    END
    ELSE
    BEGIN
        DECLARE @Pct FLOAT = CAST(@DescTables AS FLOAT) / CAST(@TotalTables AS FLOAT) * 100;
        IF @Pct >= 90 SET @Score = 3;
        ELSE IF @Pct >= 50 SET @Score = 2;
        ELSE IF @Pct >= 10 SET @Score = 1;
        ELSE SET @Score = 0;

        SET @Finding = CAST(@DescTables AS NVARCHAR) + ' of ' + CAST(@TotalTables AS NVARCHAR) + ' tables have descriptions (' + CAST(@Pct AS NVARCHAR(5)) + '%).';
    END
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    CREATE TABLE #DbResults (DbName NVARCHAR(128), DbScore INT, Finding NVARCHAR(MAX));
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT;
            DECLARE @DescTables INT;
            DECLARE @DictTableExists BIT = 0;

            SELECT @TotalTables = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.is_ms_shipped = 0;
            SELECT @DescTables = COUNT(DISTINCT t.object_id) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.class = 1 AND ep.minor_id = 0 AND ep.name = ''MS_Description'' WHERE t.is_ms_shipped = 0;
            SELECT @DictTableExists = CASE WHEN EXISTS(SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name LIKE ''%DataDictionary%'' OR t.name LIKE ''%Metadata%'' OR t.name LIKE ''%Dictionary%'') THEN 1 ELSE 0 END;

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalTables = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No user tables found; check not applicable.'';
            END
            ELSE IF @DictTableExists = 1
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''Dedicated dictionary/metadata table found.'';
            END
            ELSE
            BEGIN
                DECLARE @Pct FLOAT = CAST(@DescTables AS FLOAT) / CAST(@TotalTables AS FLOAT) * 100;
                IF @Pct >= 90 SET @DbScore = 3;
                ELSE IF @Pct >= 50 SET @DbScore = 2;
                ELSE IF @Pct >= 10 SET @DbScore = 1;
                ELSE SET @DbScore = 0;

                SET @DbFinding = CAST(@DescTables AS NVARCHAR) + '' of '' + CAST(@TotalTables AS NVARCHAR) + '' tables have descriptions ('' + CAST(@Pct AS NVARCHAR(5)) + ''%).'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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

    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
    SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
    DROP TABLE #DbResults;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;