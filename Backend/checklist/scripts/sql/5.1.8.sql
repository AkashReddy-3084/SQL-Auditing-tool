-- Checklist: Quarantine pattern: failed rows routed to error tables with failure reason
-- Scope: DATABASE
-- Scoring: 3 = error tables with reason columns found in all queried DBs; 2 = found in most; 1 = found in some; 0 = none found.

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
            WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id 
                         WHERE (t.name LIKE '%error%' OR t.name LIKE '%fail%' OR t.name LIKE '%quarantine%') 
                         AND (c.name LIKE '%reason%' OR c.name LIKE '%msg%' OR c.name LIKE '%error%')) THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id 
                         WHERE (t.name LIKE '%error%' OR t.name LIKE '%fail%' OR t.name LIKE '%quarantine%') 
                         AND (c.name LIKE '%reason%' OR c.name LIKE '%msg%' OR c.name LIKE '%error%')) 
            THEN 'Error tables with reason columns found'
            ELSE 'No quarantine/error tables with reason columns found'
        END;
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
            SET @Sql = N'INSERT INTO #DbResults (DbName, DbScore, Finding)
                SELECT @p_Db,
                CASE 
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id 
                                 WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%fail%'' OR t.name LIKE ''%quarantine%'') 
                                 AND (c.name LIKE ''%reason%'' OR c.name LIKE ''%msg%'' OR c.name LIKE ''%error%'')) THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id 
                                 WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%fail%'' OR t.name LIKE ''%quarantine%'') 
                                 AND (c.name LIKE ''%reason%'' OR c.name LIKE ''%msg%'' OR c.name LIKE ''%error%'')) 
                    THEN ''Error tables with reason columns found''
                    ELSE ''No quarantine/error tables with reason columns found''
                END';

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

-- Aggregate results
DECLARE @TotalDBs INT = (SELECT COUNT(*) FROM #DbResults);
DECLARE @PassedDBs INT = (SELECT COUNT(*) FROM #DbResults WHERE DbScore = 1);

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

IF @TotalDBs = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    SET @Score = CASE 
        WHEN @PassedDBs = @TotalDBs THEN 3
        WHEN @PassedDBs >= (@TotalDBs * 0.66) THEN 2
        WHEN @PassedDBs > 0 THEN 1
        ELSE 0 
    END;
    SET @Finding = CAST(@PassedDBs AS NVARCHAR(10)) + ' out of ' + CAST(@TotalDBs AS NVARCHAR(10)) + ' databases have error tables with reason columns.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;