-- Checklist: Primary keys defined on all tables
-- Scope: DATABASE
-- Scoring: 3: All user tables have a primary key. 2: <=3 tables missing a primary key. 1: >3 tables missing a primary key. 0: All tables missing a primary key or no user tables exist.

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

IF @EngineEdition <> 5
BEGIN
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
            DECLARE @TablesWithPK INT;
            DECLARE @MissingPKTables NVARCHAR(MAX);
            
            SELECT @TotalTables = COUNT(*) 
            FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
            WHERE t.type = ''U'' AND t.is_ms_shipped = 0;
            
            SELECT @TablesWithPK = COUNT(*) 
            FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
            WHERE t.type = ''U'' AND t.is_ms_shipped = 0 
              AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
            
            SELECT @MissingPKTables = STRING_AGG(s.name + ''.'' + t.name, '', '') 
            FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
            WHERE t.type = ''U'' AND t.is_ms_shipped = 0 
              AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
            
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);
            
            IF @TotalTables = 0
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No user tables found'';
            END
            ELSE IF @MissingPKTables IS NULL OR @MissingPKTables = ''''
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''All '' + CAST(@TotalTables AS NVARCHAR) + '' tables have a primary key defined'';
            END
            ELSE IF @TotalTables - @TablesWithPK <= 3
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = CAST(@TotalTables - @TablesWithPK AS NVARCHAR) + '' tables missing primary key: '' + @MissingPKTables;
            END
            ELSE IF @TablesWithPK > 0
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = CAST(@TotalTables - @TablesWithPK AS NVARCHAR) + '' tables missing primary key: '' + @MissingPKTables;
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''All '' + CAST(@TotalTables AS NVARCHAR) + '' tables are missing a primary key'';
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @DbScore, @DbFinding);
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
ELSE
BEGIN
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    BEGIN TRY
        DECLARE @TotalTables INT;
        DECLARE @TablesWithPK INT;
        DECLARE @MissingPKTables NVARCHAR(MAX);
        
        SELECT @TotalTables = COUNT(*) 
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
        WHERE t.type = 'U' AND t.is_ms_shipped = 0;
        
        SELECT @TablesWithPK = COUNT(*) 
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
        WHERE t.type = 'U' AND t.is_ms_shipped = 0 
          AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
        
        SELECT @MissingPKTables = STRING_AGG(s.name + '.' + t.name, ', ') 
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id 
        WHERE t.type = 'U' AND t.is_ms_shipped = 0 
          AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
        
        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);
        
        IF @TotalTables = 0
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = 'No user tables found';
        END
        ELSE IF @MissingPKTables IS NULL OR @MissingPKTables = ''
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = 'All ' + CAST(@TotalTables AS NVARCHAR) + ' tables have a primary key defined';
        END
        ELSE IF @TotalTables - @TablesWithPK <= 3
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = CAST(@TotalTables - @TablesWithPK AS NVARCHAR) + ' tables missing primary key: ' + @MissingPKTables;
        END
        ELSE IF @TablesWithPK > 0
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = CAST(@TotalTables - @TablesWithPK AS NVARCHAR) + ' tables missing primary key: ' + @MissingPKTables;
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = 'All ' + CAST(@TotalTables AS NVARCHAR) + ' tables are missing a primary key';
        END
        
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
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