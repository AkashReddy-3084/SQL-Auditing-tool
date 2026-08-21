-- Checklist: Data types appropriate and right-sized (no oversized varchar, correct numeric precision)
-- Scope: DATABASE
-- Scoring: 3: No oversized columns found. 2: 1-5 oversized columns. 1: 6-20 oversized columns. 0: >20 oversized columns.
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
    
    DECLARE @Count INT = 0;
    DECLARE @List NVARCHAR(MAX) = '';
    
    SELECT 
        @Count = COUNT(*),
        @List = STRING_AGG(s.name + '.' + t.name + '.' + c.name, ', ')
    FROM sys.columns c
    JOIN sys.types tp ON c.user_type_id = tp.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE 
        (tp.name IN ('varchar', 'char') AND (c.max_length > 1000 OR c.max_length = -1))
        OR (tp.name IN ('nvarchar', 'nchar') AND (c.max_length > 2000 OR c.max_length = -1))
        OR (tp.name IN ('decimal', 'numeric') AND (c.precision > 18 OR c.scale > 4));
        
    SET @Score = CASE 
        WHEN @Count = 0 THEN 3
        WHEN @Count BETWEEN 1 AND 5 THEN 2
        WHEN @Count BETWEEN 6 AND 20 THEN 1
        ELSE 0
    END;
    
    SET @Finding = CASE WHEN @Count = 0 THEN 'No oversized columns found' ELSE @List END;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @Score, @Finding);
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
            DECLARE @Count INT = 0;
            DECLARE @List NVARCHAR(MAX) = '''';
            
            SELECT 
                @Count = COUNT(*),
                @List = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.types tp ON c.user_type_id = tp.user_type_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE 
                (tp.name IN (''varchar'', ''char'') AND (c.max_length > 1000 OR c.max_length = -1))
                OR (tp.name IN (''nvarchar'', ''nchar'') AND (c.max_length > 2000 OR c.max_length = -1))
                OR (tp.name IN (''decimal'', ''numeric'') AND (c.precision > 18 OR c.scale > 4));
                
            DECLARE @DbScore INT = CASE 
                WHEN @Count = 0 THEN 3
                WHEN @Count BETWEEN 1 AND 5 THEN 2
                WHEN @Count BETWEEN 6 AND 20 THEN 1
                ELSE 0
            END;
            
            DECLARE @DbFinding NVARCHAR(MAX) = CASE WHEN @Count = 0 THEN ''No oversized columns found'' ELSE @List END;
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName, @DbScore, @DbFinding);
            ';
            
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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