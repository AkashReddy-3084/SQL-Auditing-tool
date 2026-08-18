-- Checklist: Technical metadata (schema) captured and current
-- Scope: DATABASE
-- Scoring: 0=No metadata found; 1=Low coverage (<50% of tables); 2=Good coverage (>=50%) or metadata schema/table exists; 3=High coverage (>=80%) or comprehensive metadata repository detected.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalTables INT;
    DECLARE @TablesWithMeta INT;
    DECLARE @HasMetaSchema BIT = 0;
    DECLARE @HasMetaTable BIT = 0;
    DECLARE @Coverage DECIMAL(5,2);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND type = ''U'';
    SELECT @TablesWithMeta = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
    WHERE t.is_ms_shipped = 0 AND t.type = ''U'';

    SELECT @HasMetaSchema = CASE WHEN EXISTS(SELECT 1 FROM sys.schemas WHERE name IN (''metadata'', ''data_dictionary'', ''mdm'', ''schema_registry'')) THEN 1 ELSE 0 END;
    SELECT @HasMetaTable = CASE WHEN EXISTS(SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name IN (''metadata'', ''data_dictionary'', ''mdm'', ''schema_registry'') OR t.name LIKE ''%metadata%'' OR t.name LIKE ''%data_dictionary%'') THEN 1 ELSE 0 END;

    SET @Coverage = CASE WHEN @TotalTables > 0 THEN (@TablesWithMeta * 100.0) / @TotalTables ELSE 0 END;

    IF @Coverage >= 80.0 OR (@HasMetaSchema = 1 AND @HasMetaTable = 1) SET @DbScore = 3;
    ELSE IF @Coverage >= 50.0 OR @HasMetaSchema = 1 OR @HasMetaTable = 1 SET @DbScore = 2;
    ELSE IF @Coverage > 0.0 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    SET @DbFinding = CONCAT(''Tables with metadata: '', @TablesWithMeta, ''/'', @TotalTables, '' ('', CAST(@Coverage AS NVARCHAR(10)), ''%'')'');
    IF @HasMetaSchema = 1 SET @DbFinding = @DbFinding + ''; Metadata schema detected'';
    IF @HasMetaTable = 1 SET @DbFinding = @DbFinding + ''; Metadata table detected'';

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
            DECLARE @TablesWithMeta INT;
            DECLARE @HasMetaSchema BIT = 0;
            DECLARE @HasMetaTable BIT = 0;
            DECLARE @Coverage DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND type = ''U'';
            SELECT @TablesWithMeta = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE t.is_ms_shipped = 0 AND t.type = ''U'';

            SELECT @HasMetaSchema = CASE WHEN EXISTS(SELECT 1 FROM sys.schemas WHERE name IN (''metadata'', ''data_dictionary'', ''mdm'', ''schema_registry'')) THEN 1 ELSE 0 END;
            SELECT @HasMetaTable = CASE WHEN EXISTS(SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name IN (''metadata'', ''data_dictionary'', ''mdm'', ''schema_registry'') OR t.name LIKE ''%metadata%'' OR t.name LIKE ''%data_dictionary%'') THEN 1 ELSE 0 END;

            SET @Coverage = CASE WHEN @TotalTables > 0 THEN (@TablesWithMeta * 100.0) / @TotalTables ELSE 0 END;

            IF @Coverage >= 80.0 OR (@HasMetaSchema = 1 AND @HasMetaTable = 1) SET @DbScore = 3;
            ELSE IF @Coverage >= 50.0 OR @HasMetaSchema = 1 OR @HasMetaTable = 1 SET @DbScore = 2;
            ELSE IF @Coverage > 0.0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            SET @DbFinding = CONCAT(''Tables with metadata: '', @TablesWithMeta, ''/'', @TotalTables, '' ('', CAST(@Coverage AS NVARCHAR(10)), ''%'')'');
            IF @HasMetaSchema = 1 SET @DbFinding = @DbFinding + ''; Metadata schema detected'';
            IF @HasMetaTable = 1 SET @DbFinding = @DbFinding + ''; Metadata table detected'';

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