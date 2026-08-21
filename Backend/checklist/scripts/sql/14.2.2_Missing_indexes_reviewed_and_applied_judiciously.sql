-- Checklist: Missing indexes reviewed and applied judiciously
-- Scope: DATABASE
-- Scoring: 3=0 significant missing indexes, 2=1-5, 1=6-20, 0=>20 significant missing index recommendations.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    BEGIN TRY
        DECLARE @MissingCount INT;
        SELECT @MissingCount = COUNT(*)
        FROM sys.dm_db_missing_index_group_stats AS migs
        JOIN sys.dm_db_missing_index_groups AS mig ON migs.group_handle = mig.index_group_handle
        WHERE migs.user_seeks > 0 AND migs.avg_total_user_cost > 100;

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @MissingCount = 0
            SET @DbScore = 3;
        ELSE IF @MissingCount <= 5
            SET @DbScore = 2;
        ELSE IF @MissingCount <= 20
            SET @DbScore = 1;
        ELSE
            SET @DbScore = 0;

        SET @DbFinding = CAST(@MissingCount AS NVARCHAR) + N' significant missing index recommendations found.';

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, @DbScore, @DbFinding);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
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
            DECLARE @MissingCount INT;
            SELECT @MissingCount = COUNT(*)
            FROM sys.dm_db_missing_index_group_stats AS migs
            JOIN sys.dm_db_missing_index_groups AS mig ON migs.group_handle = mig.index_group_handle
            WHERE migs.user_seeks > 0 AND migs.avg_total_user_cost > 100;

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @MissingCount = 0
                SET @DbScore = 3;
            ELSE IF @MissingCount <= 5
                SET @DbScore = 2;
            ELSE IF @MissingCount <= 20
                SET @DbScore = 1;
            ELSE
                SET @DbScore = 0;

            SET @DbFinding = CAST(@MissingCount AS NVARCHAR) + N'' significant missing index recommendations found.';

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