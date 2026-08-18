-- Checklist: Index usage analyzed (seeks vs scans) against workload
-- Scope: DATABASE
-- Scoring: 3=0 unused indexes, 2=1-5 unused, 1=6-20 unused, 0=>20 unused

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
    DECLARE @CurrentDbName NVARCHAR(128) = DB_NAME();
    DECLARE @UnusedCount INT;
    DECLARE @UnusedList NVARCHAR(MAX);

    SELECT @UnusedCount = COUNT(*),
           @UnusedList = STRING_AGG(s.name + '.' + t.name + '.' + i.name, ', ')
    FROM sys.indexes i
    JOIN sys.tables t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.dm_db_index_usage_stats ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = DB_ID()
    WHERE i.type_desc <> 'HEAP'
      AND (ISNULL(ius.user_seeks, 0) = 0 AND ISNULL(ius.user_scans, 0) = 0 AND ISNULL(ius.user_lookups, 0) = 0)
      AND (ISNULL(ius.user_updates, 0) > 0 OR ius.object_id IS NULL);

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT
        @CurrentDbName,
        CASE
            WHEN @UnusedCount = 0 THEN 3
            WHEN @UnusedCount <= 5 THEN 2
            WHEN @UnusedCount <= 20 THEN 1
            ELSE 0
        END,
        CASE
            WHEN @UnusedCount = 0 THEN 'No unused indexes found'
            ELSE 'Found ' + CAST(@UnusedCount AS NVARCHAR(10)) + ' unused indexes (zero reads, non-zero writes or never touched): ' + ISNULL(@UnusedList, 'None listed')
        END;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @UnusedCount INT;
            DECLARE @UnusedList NVARCHAR(MAX);

            SELECT @UnusedCount = COUNT(*),
                   @UnusedList = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '')
            FROM sys.indexes i
            JOIN sys.tables t ON i.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.dm_db_index_usage_stats ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id AND ius.database_id = DB_ID()
            WHERE i.type_desc <> ''HEAP''
              AND (ISNULL(ius.user_seeks, 0) = 0 AND ISNULL(ius.user_scans, 0) = 0 AND ISNULL(ius.user_lookups, 0) = 0)
              AND (ISNULL(ius.user_updates, 0) > 0 OR ius.object_id IS NULL);

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT
                ''' + @DbName + ''' AS DbName,
                CASE
                    WHEN @UnusedCount = 0 THEN 3
                    WHEN @UnusedCount <= 5 THEN 2
                    WHEN @UnusedCount <= 20 THEN 1
                    ELSE 0
                END AS DbScore,
                CASE
                    WHEN @UnusedCount = 0 THEN ''No unused indexes found''
                    ELSE ''Found '' + CAST(@UnusedCount AS NVARCHAR(10)) + '' unused indexes (zero reads, non-zero writes or never touched): '' + ISNULL(@UnusedList, ''None listed'')
                END AS Finding;';

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

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;