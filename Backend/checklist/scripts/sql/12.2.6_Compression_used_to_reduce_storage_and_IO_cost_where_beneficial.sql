-- Checklist: Compression used to reduce storage and IO cost where beneficial
-- Scope: DATABASE
-- Scoring: 0=0% compressed, 1=>0% to <25%, 2=>=25% to <75%, 3=>=75% or no user tables

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    SET @DatabaseQueried = DB_NAME();
    
    DECLARE @Total INT, @Compressed INT, @Pct DECIMAL(5,2), @DbScore INT, @DbFinding NVARCHAR(MAX);
    
    SELECT @Total = COUNT(DISTINCT t.object_id),
           @Compressed = COUNT(DISTINCT CASE WHEN p.data_compression > 0 THEN t.object_id END)
    FROM sys.tables t
    JOIN sys.partitions p ON t.object_id = p.object_id
    WHERE t.is_ms_shipped = 0;

    SET @Pct = CASE WHEN @Total > 0 THEN (@Compressed * 100.0 / @Total) ELSE 100.0 END;

    SET @DbScore = CASE 
        WHEN @Total = 0 THEN 3
        WHEN @Pct >= 75 THEN 3
        WHEN @Pct >= 25 THEN 2
        WHEN @Pct > 0 THEN 1
        ELSE 0
    END;

    SELECT @DbFinding = STRING_AGG(t.name, ', ')
    FROM sys.tables t
    LEFT JOIN sys.partitions p ON t.object_id = p.object_id AND p.data_compression > 0
    WHERE t.is_ms_shipped = 0 AND p.partition_id IS NULL;

    SET @DbFinding = ISNULL(@DbFinding, 'No uncompressed tables found');
    IF @DbScore >= 2 SET @DbFinding = CAST(@Pct AS NVARCHAR(10)) + '% of tables compressed';

    SET @Score = @DbScore;
    SET @Finding = @DbFinding;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    CREATE TABLE #DbResults (
        DbName NVARCHAR(128),
        DbScore INT,
        Finding NVARCHAR(MAX)
    );

    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Total INT, @Compressed INT, @Pct DECIMAL(5,2), @DbScore INT, @DbFinding NVARCHAR(MAX);
            SELECT @Total = COUNT(DISTINCT t.object_id),
                   @Compressed = COUNT(DISTINCT CASE WHEN p.data_compression > 0 THEN t.object_id END)
            FROM sys.tables t
            JOIN sys.partitions p ON t.object_id = p.object_id
            WHERE t.is_ms_shipped = 0;

            SET @Pct = CASE WHEN @Total > 0 THEN (@Compressed * 100.0 / @Total) ELSE 100.0 END;

            SET @DbScore = CASE 
                WHEN @Total = 0 THEN 3
                WHEN @Pct >= 75 THEN 3
                WHEN @Pct >= 25 THEN 2
                WHEN @Pct > 0 THEN 1
                ELSE 0
            END;

            SELECT @DbFinding = STRING_AGG(t.name, ' ')
            FROM sys.tables t
            LEFT JOIN sys.partitions p ON t.object_id = p.object_id AND p.data_compression > 0
            WHERE t.is_ms_shipped = 0 AND p.partition_id IS NULL;

            SET @DbFinding = ISNULL(@DbFinding, ''No uncompressed tables found'');
            IF @DbScore >= 2 SET @DbFinding = CAST(@Pct AS NVARCHAR(10)) + ''% of tables compressed'';

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @DbScore, @DbFinding);';
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

    DROP TABLE #DbResults;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;