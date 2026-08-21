-- Checklist: Query Store enabled and configured appropriately
-- Scope: DATABASE
-- Scoring: 3=Enabled & optimal settings; 2=Enabled & minor gaps; 1=Desired enabled but actual not/readonly; 0=Disabled.

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
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @actual_state INT, @desired_state INT, @max_storage_size_mb INT, @data_flush_interval_seconds INT, @query_capture_mode INT;
        SELECT @actual_state = actual_state, @desired_state = desired_state, @max_storage_size_mb = max_storage_size_mb, @data_flush_interval_seconds = data_flush_interval_seconds, @query_capture_mode = query_capture_mode
        FROM sys.database_query_store_options;

        DECLARE @db_score INT;
        DECLARE @db_finding NVARCHAR(MAX);

        IF @actual_state = 0 OR @desired_state = 0
            SET @db_score = 0;
        ELSE IF @actual_state = 1
        BEGIN
            IF @max_storage_size_mb >= 1024 AND @data_flush_interval_seconds <= 1200 AND @query_capture_mode IN (1, 2)
                SET @db_score = 3;
            ELSE
                SET @db_score = 2;
        END
        ELSE
            SET @db_score = 1;

        SET @db_finding = ''actual_state='' + CAST(@actual_state AS NVARCHAR(10)) + '', desired_state='' + CAST(@desired_state AS NVARCHAR(10)) + '', max_storage_size_mb='' + CAST(@max_storage_size_mb AS NVARCHAR(10)) + '', flush_interval='' + CAST(@data_flush_interval_seconds AS NVARCHAR(10)) + ''s, capture_mode='' + CAST(@query_capture_mode AS NVARCHAR(10));

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', @db_score, @db_finding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate through online user databases
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
                DECLARE @actual_state INT, @desired_state INT, @max_storage_size_mb INT, @data_flush_interval_seconds INT, @query_capture_mode INT;
                SELECT @actual_state = actual_state, @desired_state = desired_state, @max_storage_size_mb = max_storage_size_mb, @data_flush_interval_seconds = data_flush_interval_seconds, @query_capture_mode = query_capture_mode
                FROM sys.database_query_store_options;

                DECLARE @db_score INT;
                DECLARE @db_finding NVARCHAR(MAX);

                IF @actual_state = 0 OR @desired_state = 0
                    SET @db_score = 0;
                ELSE IF @actual_state = 1
                BEGIN
                    IF @max_storage_size_mb >= 1024 AND @data_flush_interval_seconds <= 1200 AND @query_capture_mode IN (1, 2)
                        SET @db_score = 3;
                    ELSE
                        SET @db_score = 2;
                END
                ELSE
                    SET @db_score = 1;

                SET @db_finding = ''actual_state='' + CAST(@actual_state AS NVARCHAR(10)) + '', desired_state='' + CAST(@desired_state AS NVARCHAR(10)) + '', max_storage_size_mb='' + CAST(@max_storage_size_mb AS NVARCHAR(10)) + '', flush_interval='' + CAST(@data_flush_interval_seconds AS NVARCHAR(10)) + ''s, capture_mode='' + CAST(@query_capture_mode AS NVARCHAR(10));

                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (''' + @DbName + ''', @db_score, @db_finding);
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