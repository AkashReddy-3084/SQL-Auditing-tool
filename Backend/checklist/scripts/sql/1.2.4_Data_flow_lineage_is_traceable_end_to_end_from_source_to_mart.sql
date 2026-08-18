-- Checklist: Data flow lineage is traceable end-to-end from source to mart
-- Scope: DATABASE
-- Scoring: 0=No lineage evidence; 1=Partial evidence (<50% of relevant objects); 2=Mostly pass (50-80% evidence or proxy dependencies); 3=Pass (>80% evidence or explicit lineage metadata across layers).
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
    DECLARE @TotalTables INT = 0;
    DECLARE @EvidenceTables INT = 0;
    
    SELECT @TotalTables = COUNT(*)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.is_ms_shipped = 0
      AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' 
           OR t.name LIKE ''%stg%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%'');
           
    SELECT @EvidenceTables = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
    WHERE t.is_ms_shipped = 0
      AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' 
           OR t.name LIKE ''%stg%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%'')
      AND (ep.value LIKE ''%lineage%'' OR ep.value LIKE ''%source%'' OR ep.value LIKE ''%etl%'' OR ep.value LIKE ''%load%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT ''' + @DbName + ''',
           CASE 
               WHEN @TotalTables = 0 THEN 3 
               WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.8 THEN 3
               WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.5 THEN 2
               WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.1 THEN 1
               ELSE 0
           END,
           ''Total relevant tables: '' + CAST(@TotalTables AS NVARCHAR) + ''; Tables with lineage evidence: '' + CAST(@EvidenceTables AS NVARCHAR);
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
            DECLARE @TotalTables INT = 0;
            DECLARE @EvidenceTables INT = 0;
            
            SELECT @TotalTables = COUNT(*)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0
              AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' 
                   OR t.name LIKE ''%stg%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%'');
                   
            SELECT @EvidenceTables = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE t.is_ms_shipped = 0
              AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' 
                   OR t.name LIKE ''%stg%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%'')
              AND (ep.value LIKE ''%lineage%'' OR ep.value LIKE ''%source%'' OR ep.value LIKE ''%etl%'' OR ep.value LIKE ''%load%'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''',
                   CASE 
                       WHEN @TotalTables = 0 THEN 3 
                       WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.8 THEN 3
                       WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.5 THEN 2
                       WHEN CAST(@EvidenceTables AS FLOAT) / NULLIF(@TotalTables, 0) >= 0.1 THEN 1
                       ELSE 0
                   END,
                   ''Total relevant tables: '' + CAST(@TotalTables AS NVARCHAR) + ''; Tables with lineage evidence: '' + CAST(@EvidenceTables AS NVARCHAR);
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