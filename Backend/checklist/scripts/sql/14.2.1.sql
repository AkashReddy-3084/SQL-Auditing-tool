-- Checklist: Index usage analyzed (seeks vs scans) against workload
-- Scope: DATABASE
-- Scoring: 3 = no indexes with scans > seeks; 2 = < 5% of indexes have scans > seeks; 1 = 5-25% have scans > seeks; 0 = > 25% have scans > seeks

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
            WHEN SUM(IsInefficient) = 0 THEN 3 
            WHEN CAST(SUM(IsInefficient) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 5 THEN 2 
            WHEN CAST(SUM(IsInefficient) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN SUM(IsInefficient) = 0 THEN 'No indexes with scans > seeks found'
            ELSE 'Indexes with scans > seeks: ' + (
                SELECT STRING_AGG(QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + ' (' + i.name + ')', ', ')
                FROM sys.indexes i
                LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
                JOIN sys.tables t ON i.object_id = t.object_id
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE i.type > 0 AND us.user_scans > us.user_seeks
            )
        END
    FROM (
        SELECT 
            i.index_id,
            CASE WHEN us.user_scans > us.user_seeks THEN 1 ELSE 0 END as IsInefficient
        FROM sys.indexes i
        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
        WHERE i.type > 0
    ) as i;
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
            SELECT 
                @p_Db,
                CASE 
                    WHEN SUM(IsInefficient) = 0 THEN 3 
                    WHEN CAST(SUM(IsInefficient) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 5 THEN 2 
                    WHEN CAST(SUM(IsInefficient) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN SUM(IsInefficient) = 0 THEN ''No indexes with scans > seeks found''
                    ELSE ''Indexes with scans > seeks: '' + (
                        SELECT STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + '' ('' + i.name + '')'', '', '')
                        FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i
                        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID(''' + @DbName + N''')
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON i.object_id = t.object_id
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                        WHERE i.type > 0 AND us.user_scans > us.user_seeks
                    )
                END
            FROM (
                SELECT 
                    i.index_id,
                    CASE WHEN us.user_scans > us.user_seeks THEN 1 ELSE 0 END as IsInefficient
                FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i
                LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID(''' + @DbName + N''')
                WHERE i.type > 0
            ) as i;';

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