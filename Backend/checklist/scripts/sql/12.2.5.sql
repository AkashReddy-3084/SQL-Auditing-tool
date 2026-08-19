-- Checklist: Unused databases/objects/indexes cleaned up
-- Scope: DATABASE
-- Scoring: 3 = no unused indexes; 2 = < 5% unused; 1 = 5-25% unused; 0 = > 25% unused

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
    DECLARE @TotalIdx INT;
    SELECT @TotalIdx = COUNT(*) FROM sys.indexes WHERE type > 0;

    SELECT 
        DB_NAME(),
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN CAST(COUNT(*) * 100.0 / NULLIF(@TotalIdx, 0) AS INT) < 5 THEN 2 
            WHEN CAST(COUNT(*) * 100.0 / NULLIF(@TotalIdx, 0) AS INT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN ''No unused indexes found''
            ELSE ''Unused indexes: '' + STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''('' + i.name + '')'', '', '') 
        END
    FROM sys.indexes i
    JOIN sys.tables t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id
    WHERE i.type > 0 AND (us.user_seeks IS NULL OR (us.user_seeks = 0 AND us.user_scans = 0 AND us.user_lookups = 0));';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
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
            SET @Sql = N'
            DECLARE @TotalIdx INT;
            SELECT @TotalIdx = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.indexes WHERE type > 0;
            
            SELECT 
                @p_Db,
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN CAST(COUNT(*) * 100.0 / NULLIF(@TotalIdx, 0) AS INT) < 5 THEN 2 
                    WHEN CAST(COUNT(*) * 100.0 / NULLIF(@TotalIdx, 0) AS INT) < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No unused indexes found''
                    ELSE ''Unused indexes: '' + STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''('' + i.name + '')'', '', '') 
                END
            FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i
            JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON i.object_id = t.object_id
            JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
            LEFT JOIN sys.dm_db_index_usage_stats us 
                ON i.object_id = us.object_id AND i.index_id = us.index_id 
                AND us.database_id = DB_ID(@p_Db)
            WHERE i.type > 0 AND (us.user_seeks IS NULL OR (us.user_seeks = 0 AND us.user_scans = 0 AND us.user_lookups = 0));';

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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;