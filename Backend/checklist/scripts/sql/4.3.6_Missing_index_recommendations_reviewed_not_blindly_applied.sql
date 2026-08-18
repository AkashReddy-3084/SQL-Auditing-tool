-- Checklist: Missing-index recommendations reviewed (not blindly applied)
-- Scope: DATABASE
-- Scoring: 3=No missing index requests found; 2=1-5 requests; 1=6-20 requests; 0=>20 requests
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (DbName NVARCHAR(128), DbScore INT, Finding NVARCHAR(MAX));

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @Count INT;
        DECLARE @Details NVARCHAR(MAX);
        
        SELECT @Count = COUNT(DISTINCT mig.index_group_handle)
        FROM sys.dm_db_missing_index_group_stats migs
        JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
        WHERE migs.user_seeks + migs.user_scans + migs.user_lookups + migs.user_updates > 0;
        
        IF @Count > 0
        BEGIN
            SELECT @Details = STRING_AGG(
                CAST(migs.user_seeks AS NVARCHAR(20)) + '' seeks, '' + 
                CAST(migs.user_scans AS NVARCHAR(20)) + '' scans, '' + 
                mid.statement,
                ''; ''
            )
            FROM sys.dm_db_missing_index_group_stats migs
            JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
            JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
            WHERE migs.user_seeks + migs.user_scans + migs.user_lookups + migs.user_updates > 0;
        END
        ELSE
        BEGIN
            SET @Details = ''No missing index requests found'';
        END
        
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + REPLACE(@DbName, '''', '''''') + ''',
            CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 5 THEN 2 WHEN @Count <= 20 THEN 1 ELSE 0 END,
            @Details
        );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
    
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                DECLARE @Count INT;
                DECLARE @Details NVARCHAR(MAX);
                
                SELECT @Count = COUNT(DISTINCT mig.index_group_handle)
                FROM sys.dm_db_missing_index_group_stats migs
                JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
                WHERE migs.user_seeks + migs.user_scans + migs.user_lookups + migs.user_updates > 0;
                
                IF @Count > 0
                BEGIN
                    SELECT @Details = STRING_AGG(
                        CAST(migs.user_seeks AS NVARCHAR(20)) + '' seeks, '' + 
                        CAST(migs.user_scans AS NVARCHAR(20)) + '' scans, '' + 
                        mid.statement,
                        ''; ''
                    )
                    FROM sys.dm_db_missing_index_group_stats migs
                    JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
                    JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
                    WHERE migs.user_seeks + migs.user_scans + migs.user_lookups + migs.user_updates > 0;
                END
                ELSE
                BEGIN
                    SET @Details = ''No missing index requests found'';
                END
                
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (
                    ''' + REPLACE(@DbName, '''', '''''') + ''',
                    CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 5 THEN 2 WHEN @Count <= 20 THEN 1 ELSE 0 END,
                    @Details
                );
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
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