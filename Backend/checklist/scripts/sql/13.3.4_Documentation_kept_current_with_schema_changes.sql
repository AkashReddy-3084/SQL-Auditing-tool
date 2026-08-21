-- Checklist: Documentation kept current with schema changes
-- Scope: DATABASE
-- Scoring: 0: <10% coverage, 1: 10-49%, 2: 50-89%, 3: >=90% coverage of tables/columns with extended properties. NOTE: This script provides automated evidence. Full compliance requires human review.

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    
    DECLARE @TotalTables INT, @TotalColumns INT, @DocTables INT, @DocColumns INT;
    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = 'U';
    SELECT @TotalColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = 'U';
    SELECT @DocTables = COUNT(DISTINCT ep.major_id) FROM sys.extended_properties ep JOIN sys.tables t ON ep.major_id = t.object_id WHERE ep.name = 'MS_Description' AND t.type = 'U';
    SELECT @DocColumns = COUNT(*) FROM sys.extended_properties ep JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id WHERE ep.name = 'MS_Description';
    
    DECLARE @Total INT = @TotalTables + @TotalColumns;
    DECLARE @DocTotal INT = @DocTables + @DocColumns;
    DECLARE @Coverage DECIMAL(5,2) = CASE WHEN @Total = 0 THEN 100.0 ELSE (@DocTotal * 100.0) / @Total END;
    DECLARE @DbScore INT = CASE 
        WHEN @Coverage >= 90 THEN 3
        WHEN @Coverage >= 50 THEN 2
        WHEN @Coverage >= 10 THEN 1
        ELSE 0
    END;
    DECLARE @DbFinding NVARCHAR(MAX) = 'Coverage: ' + CAST(@Coverage AS NVARCHAR(10)) + '% (' + CAST(@DocTotal AS NVARCHAR(10)) + '/' + CAST(@Total AS NVARCHAR(10)) + ')';
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE -- SQL Server / Azure SQL Managed Instance
BEGIN
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
            DECLARE @TotalTables INT, @TotalColumns INT, @DocTables INT, @DocColumns INT;
            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
            SELECT @TotalColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'';
            SELECT @DocTables = COUNT(DISTINCT ep.major_id) FROM sys.extended_properties ep JOIN sys.tables t ON ep.major_id = t.object_id WHERE ep.name = ''MS_Description'' AND t.type = ''U'';
            SELECT @DocColumns = COUNT(*) FROM sys.extended_properties ep JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id WHERE ep.name = ''MS_Description'';
            
            DECLARE @Total INT = @TotalTables + @TotalColumns;
            DECLARE @DocTotal INT = @DocTables + @DocColumns;
            DECLARE @Coverage DECIMAL(5,2) = CASE WHEN @Total = 0 THEN 100.0 ELSE (@DocTotal * 100.0) / @Total END;
            DECLARE @DbScore INT = CASE 
                WHEN @Coverage >= 90 THEN 3
                WHEN @Coverage >= 50 THEN 2
                WHEN @Coverage >= 10 THEN 1
                ELSE 0
            END;
            DECLARE @DbFinding NVARCHAR(MAX) = ''Coverage: '' + CAST(@Coverage AS NVARCHAR(10)) + ''% ('' + CAST(@DocTotal AS NVARCHAR(10)) + ''/'' + CAST(@Total AS NVARCHAR(10)) + '')'';
            
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