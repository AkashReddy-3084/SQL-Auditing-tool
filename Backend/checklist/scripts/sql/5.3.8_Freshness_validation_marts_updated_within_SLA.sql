-- Checklist: Freshness validation: marts updated within SLA
-- Scope: DATABASE
-- Scoring: 0: No updates in >48h; 1: 24-48h; 2: 1-24h; 3: <1h. Proxy for SLA.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

SET NOCOUNT ON;

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @MaxUpdate DATETIME;
    DECLARE @HoursDiff FLOAT;
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @MaxUpdate = MAX(ius.last_user_update)
    FROM sys.dm_db_index_usage_stats ius
    JOIN sys.tables t ON ius.object_id = t.object_id
    WHERE ius.database_id = DB_ID();

    IF @MaxUpdate IS NULL
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No recent table updates detected'';
    END
    ELSE
    BEGIN
        SET @HoursDiff = DATEDIFF(HOUR, @MaxUpdate, GETUTCDATE());
        SET @DbScore = CASE
            WHEN @HoursDiff < 1 THEN 3
            WHEN @HoursDiff < 24 THEN 2
            WHEN @HoursDiff < 48 THEN 1
            ELSE 0
        END;
        SET @DbFinding = ''Most recent update: '' + CONVERT(NVARCHAR(30), @MaxUpdate, 120) + '' ('' + CAST(@HoursDiff AS NVARCHAR(10)) + '' hours ago)'';
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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
            DECLARE @MaxUpdate DATETIME;
            DECLARE @HoursDiff FLOAT;
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @MaxUpdate = MAX(ius.last_user_update)
            FROM sys.dm_db_index_usage_stats ius
            JOIN sys.tables t ON ius.object_id = t.object_id
            WHERE ius.database_id = DB_ID();

            IF @MaxUpdate IS NULL
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No recent table updates detected'';
            END
            ELSE
            BEGIN
                SET @HoursDiff = DATEDIFF(HOUR, @MaxUpdate, GETUTCDATE());
                SET @DbScore = CASE
                    WHEN @HoursDiff < 1 THEN 3
                    WHEN @HoursDiff < 24 THEN 2
                    WHEN @HoursDiff < 48 THEN 1
                    ELSE 0
                END;
                SET @DbFinding = ''Most recent update: '' + CONVERT(NVARCHAR(30), @MaxUpdate, 120) + '' ('' + CAST(@HoursDiff AS NVARCHAR(10)) + '' hours ago)'';
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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