-- Checklist: Fill factor tuned for volatile tables where needed
-- Scope: DATABASE
-- Scoring: 3=All volatile indexes tuned (fill_factor 1-99) or none exist; 2=>=80% tuned; 1=>=50% tuned; 0=<50% tuned. Volatile defined as user_updates>1000 and user_updates>reads.
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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalVolatile INT = 0;
    DECLARE @TunedVolatile INT = 0;
    DECLARE @NonCompliant NVARCHAR(MAX) = NULL;

    SELECT 
        @TotalVolatile = COUNT(*),
        @TunedVolatile = SUM(CASE WHEN i.fill_factor > 0 AND i.fill_factor < 100 THEN 1 ELSE 0 END)
    FROM sys.indexes i
    JOIN sys.tables t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.dm_db_index_usage_stats us 
        ON i.object_id = us.object_id 
        AND i.index_id = us.index_id 
        AND us.database_id = DB_ID()
    WHERE us.user_updates > 1000 
      AND us.user_updates > ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0);

    IF @TotalVolatile > 0
    BEGIN
        SELECT @NonCompliant = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '')
        FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        LEFT JOIN sys.dm_db_index_usage_stats us 
            ON i.object_id = us.object_id 
            AND i.index_id = us.index_id 
            AND us.database_id = DB_ID()
        WHERE us.user_updates > 1000 
          AND us.user_updates > ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0)
          AND (i.fill_factor = 0 OR i.fill_factor = 100);
    END

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalVolatile = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No volatile tables detected based on current usage statistics.'';
    END
    ELSE
    BEGIN
        DECLARE @Pct FLOAT = CAST(@TunedVolatile AS FLOAT) / @TotalVolatile * 100;
        SET @DbScore = CASE 
            WHEN @Pct >= 100 THEN 3
            WHEN @Pct >= 80 THEN 2
            WHEN @Pct >= 50 THEN 1
            ELSE 0
        END;
        SET @DbFinding = CASE 
            WHEN @DbScore = 3 THEN ''All volatile indexes have fill_factor < 100.''
            ELSE ''Non-compliant indexes (fill_factor=0 or 100): '' + ISNULL(@NonCompliant, ''None'')
        END;
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE -- SQL Server / Azure SQL MI
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
            DECLARE @TotalVolatile INT = 0;
            DECLARE @TunedVolatile INT = 0;
            DECLARE @NonCompliant NVARCHAR(MAX) = NULL;

            SELECT 
                @TotalVolatile = COUNT(*),
                @TunedVolatile = SUM(CASE WHEN i.fill_factor > 0 AND i.fill_factor < 100 THEN 1 ELSE 0 END)
            FROM sys.indexes i
            JOIN sys.tables t ON i.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.dm_db_index_usage_stats us 
                ON i.object_id = us.object_id 
                AND i.index_id = us.index_id 
                AND us.database_id = DB_ID()
            WHERE us.user_updates > 1000 
              AND us.user_updates > ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0);

            IF @TotalVolatile > 0
            BEGIN
                SELECT @NonCompliant = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '')
                FROM sys.indexes i
                JOIN sys.tables t ON i.object_id = t.object_id
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                LEFT JOIN sys.dm_db_index_usage_stats us 
                    ON i.object_id = us.object_id 
                    AND i.index_id = us.index_id 
                    AND us.database_id = DB_ID()
                WHERE us.user_updates > 1000 
                  AND us.user_updates > ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0)
                  AND (i.fill_factor = 0 OR i.fill_factor = 100);
            END

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalVolatile = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No volatile tables detected based on current usage statistics.'';
            END
            ELSE
            BEGIN
                DECLARE @Pct FLOAT = CAST(@TunedVolatile AS FLOAT) / @TotalVolatile * 100;
                SET @DbScore = CASE 
                    WHEN @Pct >= 100 THEN 3
                    WHEN @Pct >= 80 THEN 2
                    WHEN @Pct >= 50 THEN 1
                    ELSE 0
                END;
                SET @DbFinding = CASE 
                    WHEN @DbScore = 3 THEN ''All volatile indexes have fill_factor < 100.''
                    ELSE ''Non-compliant indexes (fill_factor=0 or 100): '' + ISNULL(@NonCompliant, ''None'')
                END;
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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