SET NOCOUNT ON;

-- Checklist: Data compression (row/page/columnstore) applied where beneficial
-- Scope: DATABASE
-- Scoring: 3=No uncompressed tables found; 2=1-2 uncompressed tables; 1=3-5 uncompressed tables; 0=>5 uncompressed tables

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
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Cnt INT;
    DECLARE @ScoreVal INT;
    DECLARE @FindVal NVARCHAR(MAX);

    SELECT @Cnt = COUNT(*),
           @FindVal = STRING_AGG(SCHEMA_NAME(t.schema_id) + ''.'' + t.name, '', '')
    FROM sys.tables t
    JOIN sys.dm_db_index_physical_stats(DB_ID(), t.object_id, NULL, NULL, ''LIMITED'') ips
      ON t.object_id = ips.object_id
    WHERE ips.index_id < 2
      AND ips.data_compression_desc = ''NONE''
      AND ips.page_count > 1000;

    SET @ScoreVal = CASE
        WHEN @Cnt = 0 THEN 3
        WHEN @Cnt <= 2 THEN 2
        WHEN @Cnt <= 5 THEN 1
        ELSE 0
    END;

    SET @FindVal = ISNULL(@FindVal, ''No uncompressed tables found'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @ScoreVal, @FindVal);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
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
            DECLARE @Cnt INT;
            DECLARE @ScoreVal INT;
            DECLARE @FindVal NVARCHAR(MAX);

            SELECT @Cnt = COUNT(*),
                   @FindVal = STRING_AGG(SCHEMA_NAME(t.schema_id) + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.dm_db_index_physical_stats(DB_ID(), t.object_id, NULL, NULL, ''LIMITED'') ips
              ON t.object_id = ips.object_id
            WHERE ips.index_id < 2
              AND ips.data_compression_desc = ''NONE''
              AND ips.page_count > 1000;

            SET @ScoreVal = CASE
                WHEN @Cnt = 0 THEN 3
                WHEN @Cnt <= 2 THEN 2
                WHEN @Cnt <= 5 THEN 1
                ELSE 0
            END;

            SET @FindVal = ISNULL(@FindVal, ''No uncompressed tables found'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @ScoreVal, @FindVal);
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