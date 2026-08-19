-- Checklist: Auto-create statistics enabled where appropriate
-- Scope: DATABASE
-- Scoring: 3 = all user databases enabled; 2 = >80% enabled; 1 = >50% enabled; 0 = <=50% enabled

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME(),
           CASE WHEN is_auto_create_stats_on = 1 THEN 3 ELSE 0 END,
           CASE WHEN is_auto_create_stats_on = 1 THEN 'Auto-create statistics = ON'
                ELSE 'Auto-create statistics = OFF' END
    FROM sys.databases
    WHERE name = DB_NAME();
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            -- We query sys.databases from the current context as it contains the setting for all DBs
            -- but we iterate to maintain the DATABASE scope structure and handle permissions.
            SET @Sql = N'SELECT @p_Db, 
                CASE WHEN is_auto_create_stats_on = 1 THEN 3 ELSE 0 END, 
                CASE WHEN is_auto_create_stats_on = 1 THEN ''Auto-create statistics = ON'' 
                     ELSE ''Auto-create statistics = OFF'' END 
                FROM sys.databases WHERE name = @p_Db';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

-- Calculate aggregate score based on proportion of compliant databases
DECLARE @TotalDB INT = 0;
DECLARE @PassDB INT = 0;

SELECT @TotalDB = COUNT(*) FROM #DbResults;
SELECT @PassDB = COUNT(*) FROM #DbResults WHERE DbScore = 3;

IF @TotalDB = 0
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No findings');
    
    SET @Score = CASE 
        WHEN CAST(@PassDB AS FLOAT) / NULLIF(@TotalDB, 0) = 1.0 THEN 3
        WHEN CAST(@PassDB AS FLOAT) / NULLIF(@TotalDB, 0) > 0.8 THEN 2
        WHEN CAST(@PassDB AS FLOAT) / NULLIF(@TotalDB, 0) > 0.5 THEN 1
        ELSE 0 
    END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;