-- Checklist: Unused/duplicate indexes removed
-- Scope: DATABASE
-- Scoring: 3 = no unused/duplicate indexes; 2 = < 5% of total indexes are unused/duplicate; 1 = 5-25% are unused/duplicate; 0 = > 25% are unused/duplicate

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
           CASE 
             WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) = 0 THEN 3
             WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) < 0.05 THEN 2
             WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) < 0.25 THEN 1
             ELSE 0 
           END,
           CASE 
             WHEN COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) = 0 THEN 'No unused or duplicate indexes found'
             ELSE 'Unused/Duplicate: ' + STRING_AGG(CAST(IndexName AS NVARCHAR(MAX)), ', ') 
           END
    FROM (
        SELECT i.index_id AS IndexId, i.name AS IndexName,
               CASE WHEN i.index_id > 1 AND (us.user_seeks = 0 AND us.user_scans = 0 AND us.user_lookups = 0) THEN 1 ELSE 0 END AS IsUnused,
               CASE WHEN EXISTS (
                   SELECT 1 FROM sys.index_columns ic1 
                   JOIN sys.index_columns ic2 ON ic1.object_id = ic2.object_id AND ic1.column_id = ic2.column_id
                   WHERE ic1.index_id = i.index_id AND ic2.index_id <> i.index_id 
                   AND i.type = 1 -- Nonclustered
                   GROUP BY ic2.index_id HAVING COUNT(*) = (SELECT COUNT(*) FROM sys.index_columns WHERE index_id = i.index_id AND object_id = i.object_id)
               ) THEN 1 ELSE 0 END AS IsDuplicate
        FROM sys.indexes i
        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
        WHERE i.type > 0 -- Ignore heaps
    ) AS t;
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
            SELECT @p_Db,
                   CASE 
                     WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) = 0 THEN 3
                     WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) < 0.05 THEN 2
                     WHEN (CAST(COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) AS FLOAT) / NULLIF(COUNT(DISTINCT IndexId), 0)) < 0.25 THEN 1
                     ELSE 0 
                   END,
                   CASE 
                     WHEN COUNT(DISTINCT CASE WHEN IsDuplicate = 1 OR IsUnused = 1 THEN IndexId END) = 0 THEN ''No unused or duplicate indexes found''
                     ELSE ''Unused/Duplicate: '' + STRING_AGG(CAST(IndexName AS NVARCHAR(MAX)), '', '') 
                   END
            FROM (
                SELECT i.index_id AS IndexId, i.name AS IndexName,
                       CASE WHEN i.index_id > 1 AND (us.user_seeks = 0 AND us.user_scans = 0 AND us.user_lookups = 0) THEN 1 ELSE 0 END AS IsUnused,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.index_columns ic1 
                           JOIN ' + QUOTENAME(@DbName) + N'.sys.index_columns ic2 ON ic1.object_id = ic2.object_id AND ic1.column_id = ic2.column_id
                           WHERE ic1.index_id = i.index_id AND ic2.index_id <> i.index_id 
                           AND i.type = 1
                           GROUP BY ic2.index_id HAVING COUNT(*) = (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.index_columns WHERE index_id = i.index_id AND object_id = i.object_id)
                       ) THEN 1 ELSE 0 END AS IsDuplicate
                FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i
                LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID(''' + @DbName + N''')
                WHERE i.type > 0
            ) AS t;';

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