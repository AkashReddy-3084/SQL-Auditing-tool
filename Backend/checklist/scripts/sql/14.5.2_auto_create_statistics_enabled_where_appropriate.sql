-- Checklist: Auto-create statistics enabled where appropriate
-- Scope: DATABASE
-- Scoring: 3: 100% of evaluated databases have AUTO_CREATE_STATISTICS enabled. 2: 75-99% enabled. 1: 25-74% enabled. 0: 0-24% enabled.

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
    -- Azure SQL Database: Evaluate current database only
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE WHEN is_auto_create_stats_on = 1 THEN 3 ELSE 0 END,
        CASE WHEN is_auto_create_stats_on = 1 THEN 'AUTO_CREATE_STATISTICS is ON' ELSE 'AUTO_CREATE_STATISTICS is OFF' END
    FROM sys.databases;
END
ELSE
BEGIN
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
                ''' + @DbName + ''' AS DbName,
                CASE WHEN is_auto_create_stats_on = 1 THEN 3 ELSE 0 END AS DbScore,
                CASE WHEN is_auto_create_stats_on = 1 THEN ''AUTO_CREATE_STATISTICS is ON'' ELSE ''AUTO_CREATE_STATISTICS is OFF'' END AS Finding
            FROM sys.databases;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
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

-- Calculate overall score based on percentage of compliant databases
DECLARE @TotalDBs INT = (SELECT COUNT(*) FROM #DbResults);
DECLARE @CompliantDBs INT = (SELECT COUNT(*) FROM #DbResults WHERE DbScore = 3);

IF @TotalDBs = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No user databases found to evaluate.';
END
ELSE
BEGIN
    DECLARE @PctCompliant DECIMAL(5,2) = (@CompliantDBs * 100.0) / @TotalDBs;
    
    IF @PctCompliant >= 100 SET @Score = 3;
    ELSE IF @PctCompliant >= 75 SET @Score = 2;
    ELSE IF @PctCompliant >= 25 SET @Score = 1;
    ELSE SET @Score = 0;
    
    SET @Finding = ISNULL(
        (
            SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
            FROM #DbResults
            WHERE DbScore < 3
        ),
        'All evaluated databases have AUTO_CREATE_STATISTICS enabled.'
    );
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;