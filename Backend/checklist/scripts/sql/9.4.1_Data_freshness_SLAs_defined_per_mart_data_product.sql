-- Checklist: Data freshness SLAs defined per mart/data product
-- Scope: DATABASE
-- Scoring: 3: >80% of tables have SLA/freshness extended properties; 2: 20-80%; 1: 1-19%; 0: 0%. Proxy evidence. Full compliance requires human review.

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
    DECLARE @TotalTables INT;
    DECLARE @SLATables INT;
    DECLARE @Coverage DECIMAL(5,2);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
    
    SELECT @SLATables = COUNT(DISTINCT t.object_id)
    FROM sys.tables t
    JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
    WHERE t.is_ms_shipped = 0
      AND (ep.name LIKE ''%SLA%'' OR ep.name LIKE ''%Freshness%'' OR ep.name LIKE ''%Refresh%'' OR ep.name LIKE ''%DataProduct%'');

    SET @Coverage = CASE WHEN @TotalTables > 0 THEN (@SLATables * 100.0) / @TotalTables ELSE 0 END;

    SET @DbScore = CASE 
        WHEN @Coverage > 80 THEN 3
        WHEN @Coverage >= 20 THEN 2
        WHEN @Coverage >= 1 THEN 1
        ELSE 0 
    END;

    SET @DbFinding = ''Tables with SLA/Freshness metadata: '' + CAST(@SLATables AS NVARCHAR) + '' / '' + CAST(@TotalTables AS NVARCHAR) + '' ('' + CAST(@Coverage AS NVARCHAR) + ''% coverage)'';

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
            DECLARE @TotalTables INT;
            DECLARE @SLATables INT;
            DECLARE @Coverage DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
            
            SELECT @SLATables = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE t.is_ms_shipped = 0
              AND (ep.name LIKE ''%SLA%'' OR ep.name LIKE ''%Freshness%'' OR ep.name LIKE ''%Refresh%'' OR ep.name LIKE ''%DataProduct%'');

            SET @Coverage = CASE WHEN @TotalTables > 0 THEN (@SLATables * 100.0) / @TotalTables ELSE 0 END;

            SET @DbScore = CASE 
                WHEN @Coverage > 80 THEN 3
                WHEN @Coverage >= 20 THEN 2
                WHEN @Coverage >= 1 THEN 1
                ELSE 0 
            END;

            SET @DbFinding = ''Tables with SLA/Freshness metadata: '' + CAST(@SLATables AS NVARCHAR) + '' / '' + CAST(@TotalTables AS NVARCHAR) + '' ('' + CAST(@Coverage AS NVARCHAR) + ''% coverage)'';

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

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
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