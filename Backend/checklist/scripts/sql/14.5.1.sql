-- Checklist: Statistics kept current (auto-update on, plus manual updates after large loads)
-- Scope: DATABASE
-- Scoring: 3 = auto-update ON and no stats with >10% modifications; 2 = auto-update ON and some stats outdated; 1 = auto-update OFF but some stats current; 0 = auto-update OFF and stats outdated.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Sql = N'
    DECLARE @AutoUpdate BIT = (SELECT is_auto_update_stats_on FROM sys.databases WHERE name = DB_NAME());
    DECLARE @OutdatedCount INT = 0;

    SELECT @OutdatedCount = COUNT(*) 
    FROM sys.stats s 
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) 
    WHERE modification_counter > (rows * 0.1);

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE 
            WHEN @AutoUpdate = 1 THEN (CASE WHEN @OutdatedCount = 0 THEN 3 ELSE 2 END)
            ELSE (CASE WHEN @OutdatedCount = 0 THEN 1 ELSE 0 END)
        END,
        ''AutoUpdate='' + CAST(@AutoUpdate AS NVARCHAR(1)) + 
        CASE WHEN @OutdatedCount > 0 THEN ''; Outdated stats found ('' + CAST(@OutdatedCount AS NVARCHAR(10)) + '' stats > 10% mod)'' ELSE ''; No stats > 10% mod'' END
    );';
    EXEC sp_executesql @Sql;
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
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @AutoUpdate BIT = (SELECT is_auto_update_stats_on FROM sys.databases WHERE name = @p_Db);
            DECLARE @OutdatedCount INT = 0;

            SELECT @OutdatedCount = COUNT(*) 
            FROM sys.stats s 
            CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) 
            WHERE modification_counter > (rows * 0.1);

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                @p_Db,
                CASE 
                    WHEN @AutoUpdate = 1 THEN (CASE WHEN @OutdatedCount = 0 THEN 3 ELSE 2 END)
                    ELSE (CASE WHEN @OutdatedCount = 0 THEN 1 ELSE 0 END)
                END,
                ''AutoUpdate='' + CAST(@AutoUpdate AS NVARCHAR(1)) + 
                CASE WHEN @OutdatedCount > 0 THEN ''; Outdated stats found ('' + CAST(@OutdatedCount AS NVARCHAR(10)) + '' stats > 10% mod)'' ELSE ''; No stats > 10% mod'' END
            );';

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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;