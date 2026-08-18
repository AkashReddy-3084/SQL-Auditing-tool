-- Checklist: Partition alignment supports fast load/switch and purge (sliding window)
-- Scope: DATABASE
-- Scoring: 0: Misaligned partitioned tables/indexes found. 1: Partial alignment. 2: Mostly aligned. 3: Fully aligned or no partitioned objects.

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
    SELECT
        DbName = ''' + @DbName + ''',
        DbScore = CASE WHEN COUNT(*) = 0 THEN 3 ELSE 0 END,
        Finding = CASE WHEN COUNT(*) = 0 THEN ''All partitioned tables and indexes are aligned'' ELSE ''Misaligned tables: '' + STRING_AGG(TableName, '','') END
    FROM (
        SELECT t.name AS TableName
        FROM sys.tables t
        JOIN sys.indexes i ON t.object_id = i.object_id
        JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
        WHERE t.type = ''U''
        GROUP BY t.object_id, t.name
        HAVING COUNT(DISTINCT ps.name) > 1
    ) AS Misaligned;
    ';
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;

    IF NOT EXISTS (SELECT 1 FROM #DbResults WHERE DbName = @DbName)
    BEGIN
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 3, 'No partitioned tables found');
    END
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            SELECT
                DbName = ''' + @DbName + ''',
                DbScore = CASE WHEN COUNT(*) = 0 THEN 3 ELSE 0 END,
                Finding = CASE WHEN COUNT(*) = 0 THEN ''All partitioned tables and indexes are aligned'' ELSE ''Misaligned tables: '' + STRING_AGG(TableName, '','') END
            FROM (
                SELECT t.name AS TableName
                FROM sys.tables t
                JOIN sys.indexes i ON t.object_id = i.object_id
                JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
                WHERE t.type = ''U''
                GROUP BY t.object_id, t.name
                HAVING COUNT(DISTINCT ps.name) > 1
            ) AS Misaligned;
            ';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql;

            IF NOT EXISTS (SELECT 1 FROM #DbResults WHERE DbName = @DbName)
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (@DbName, 3, 'No partitioned tables found');
            END
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