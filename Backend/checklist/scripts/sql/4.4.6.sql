-- Checklist: Storage growth monitored; autogrowth settings sane (fixed size, not tiny %)
-- Scope: DATABASE
-- Scoring: 3 = all files fixed size >= 64MB; 2 = all fixed but some < 64MB; 1 = some files use percentage growth; 0 = most/all files use percentage growth or growth is disabled.

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
    SELECT 
        DB_NAME(),
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN MAX(CAST(is_percent AS INT)) = 0 AND MIN(CASE WHEN is_percent = 0 THEN growth ELSE 0 END) >= 65536 THEN 3
            WHEN MAX(CAST(is_percent AS INT)) = 0 THEN 2
            WHEN MIN(CAST(is_percent AS INT)) = 0 THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN MAX(CAST(is_percent AS INT)) = 0 AND MIN(CASE WHEN is_percent = 0 THEN growth ELSE 0 END) >= 65536 THEN 'All files fixed size >= 64MB'
            WHEN MAX(CAST(is_percent AS INT)) = 0 THEN 'All files fixed but some < 64MB'
            WHEN MIN(CAST(is_percent AS INT)) = 0 THEN 'Some files use percentage growth'
            ELSE 'Most/all files use percentage growth or growth is disabled'
        END
    FROM sys.database_files;
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
            SET @Sql = N'SELECT 
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN MAX(CAST(is_percent AS INT)) = 0 AND MIN(CASE WHEN is_percent = 0 THEN growth ELSE 0 END) >= 65536 THEN 3
                    WHEN MAX(CAST(is_percent AS INT)) = 0 THEN 2
                    WHEN MIN(CAST(is_percent AS INT)) = 0 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN MAX(CAST(is_percent AS INT)) = 0 AND MIN(CASE WHEN is_percent = 0 THEN growth ELSE 0 END) >= 65536 THEN ''All files fixed size >= 64MB''
                    WHEN MAX(CAST(is_percent AS INT)) = 0 THEN ''All files fixed but some < 64MB''
                    WHEN MIN(CAST(is_percent AS INT)) = 0 THEN ''Some files use percentage growth''
                    ELSE ''Most/all files use percentage growth or growth is disabled''
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.database_files;';

            DECLARE @TempScore INT, @TempFinding NVARCHAR(MAX);
            CREATE TABLE #SingleDbResult (DbScore INT, Finding NVARCHAR(MAX));
            INSERT INTO #SingleDbResult EXEC sp_executesql @Sql;
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT @DbName, DbScore, Finding FROM #SingleDbResult;
            
            DROP TABLE #SingleDbResult;
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;