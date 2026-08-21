-- Checklist: Unused indexes identified and removed (DMV evidence)
-- Scope: DATABASE
-- Scoring: 3: No unused indexes found. 2: 1-3 unused indexes found. 1: 4-9 unused indexes found. 0: >=10 unused indexes found.
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
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @UnusedCount INT;
    DECLARE @UnusedList NVARCHAR(MAX);

    SELECT @UnusedCount = COUNT(*),
           @UnusedList = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '') WITHIN GROUP (ORDER BY s.name, t.name, i.name)
    FROM (
        SELECT us.object_id, us.index_id,
               SUM(us.user_updates) AS total_updates,
               SUM(us.user_scans) AS total_scans,
               SUM(us.user_seeks) AS total_seeks,
               SUM(us.user_lookups) AS total_lookups
        FROM sys.dm_db_index_usage_stats us
        WHERE us.database_id = DB_ID()
        GROUP BY us.object_id, us.index_id
    ) us
    JOIN sys.indexes i ON us.object_id = i.object_id AND us.index_id = i.index_id
    JOIN sys.tables t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE i.type > 1
      AND us.total_updates > 0
      AND us.total_scans = 0
      AND us.total_seeks = 0
      AND us.total_lookups = 0;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE
            WHEN ISNULL(@UnusedCount, 0) = 0 THEN 3
            WHEN ISNULL(@UnusedCount, 0) <= 3 THEN 2
            WHEN ISNULL(@UnusedCount, 0) <= 9 THEN 1
            ELSE 0
        END,
        ISNULL(@UnusedList, ''No unused indexes found'')
    );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
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
            DECLARE @UnusedCount INT;
            DECLARE @UnusedList NVARCHAR(MAX);

            SELECT @UnusedCount = COUNT(*),
                   @UnusedList = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '') WITHIN GROUP (ORDER BY s.name, t.name, i.name)
            FROM (
                SELECT us.object_id, us.index_id,
                       SUM(us.user_updates) AS total_updates,
                       SUM(us.user_scans) AS total_scans,
                       SUM(us.user_seeks) AS total_seeks,
                       SUM(us.user_lookups) AS total_lookups
                FROM sys.dm_db_index_usage_stats us
                WHERE us.database_id = DB_ID()
                GROUP BY us.object_id, us.index_id
            ) us
            JOIN sys.indexes i ON us.object_id = i.object_id AND us.index_id = i.index_id
            JOIN sys.tables t ON i.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE i.type > 1
              AND us.total_updates > 0
              AND us.total_scans = 0
              AND us.total_seeks = 0
              AND us.total_lookups = 0;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + N''',
                CASE
                    WHEN ISNULL(@UnusedCount, 0) = 0 THEN 3
                    WHEN ISNULL(@UnusedCount, 0) <= 3 THEN 2
                    WHEN ISNULL(@UnusedCount, 0) <= 9 THEN 1
                    ELSE 0
                END,
                ISNULL(@UnusedList, ''No unused indexes found'')
            );
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