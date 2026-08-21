-- Checklist: Partition alignment supports fast load/switch and purge (sliding window)
-- Scope: DATABASE
-- Scoring: 3 = all partitioned tables are aligned; 2 = >95% aligned; 1 = >75% aligned; 0 = <=75% aligned or error.

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
           CASE WHEN COUNT(*) = 0 THEN 3 
                WHEN COUNT(CASE WHEN is_aligned = 0 THEN 1 END) * 1.0 / NULLIF(COUNT(*), 0) < 0.05 THEN 2
                WHEN COUNT(CASE WHEN is_aligned = 0 THEN 1 END) * 1.0 / NULLIF(COUNT(*), 0) < 0.25 THEN 1
                ELSE 0 END,
           CASE WHEN COUNT(*) = 0 THEN 'No partitioned tables found'
                ELSE 'Misaligned: ' + ISNULL(STRING_AGG(CASE WHEN is_aligned = 0 THEN table_name END, ', '), 'None') END
    FROM (
        SELECT 
            QUOTENAME(s.name) + '.' + QUOTENAME(t.name) as table_name,
            CASE WHEN EXISTS (
                SELECT 1 FROM sys.indexes i_nc 
                JOIN sys.data_spaces ds_nc ON i_nc.data_space_id = ds_nc.data_space_id
                JOIN sys.partition_schemes ps_nc ON ds_nc.data_space_id = ps_nc.data_space_id
                JOIN sys.indexes i_cl ON i_cl.object_id = i_nc.object_id AND i_cl.type <= 1
                JOIN sys.data_spaces ds_cl ON i_cl.data_space_id = ds_cl.data_space_id
                JOIN sys.partition_schemes ps_cl ON ds_cl.data_space_id = ps_cl.data_space_id
                WHERE i_nc.object_id = t.object_id 
                AND i_nc.index_id <> i_cl.index_id
                AND ps_nc.function_id <> ps_cl.function_id
            ) THEN 0 ELSE 1 END as is_aligned
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.indexes i ON t.object_id = i.object_id
        WHERE i.type <= 1 -- Clustered index or Heap
        AND i.data_space_id > 0 -- Table is partitioned
    ) AS AlignmentCheck;
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
            SET @Sql = N'SELECT @p_Db,
                CASE WHEN COUNT(*) = 0 THEN 3 
                    WHEN COUNT(CASE WHEN is_aligned = 0 THEN 1 END) * 1.0 / NULLIF(COUNT(*), 0) < 0.05 THEN 2
                    WHEN COUNT(CASE WHEN is_aligned = 0 THEN 1 END) * 1.0 / NULLIF(COUNT(*), 0) < 0.25 THEN 1
                    ELSE 0 END,
                CASE WHEN COUNT(*) = 0 THEN ''No partitioned tables found''
                     ELSE ''Misaligned: '' + ISNULL(STRING_AGG(CASE WHEN is_aligned = 0 THEN table_name END, '', ''), ''None'') END
                FROM (
                    SELECT 
                        QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) as table_name,
                        CASE WHEN EXISTS (
                            SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i_nc 
                            JOIN ' + QUOTENAME(@DbName) + N'.sys.data_spaces ds_nc ON i_nc.data_space_id = ds_nc.data_space_id
                            JOIN ' + QUOTENAME(@DbName) + N'.sys.partition_schemes ps_nc ON ds_nc.data_space_id = ps_nc.data_space_id
                            JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i_cl ON i_cl.object_id = i_nc.object_id AND i_cl.type <= 1
                            JOIN ' + QUOTENAME(@DbName) + N'.sys.data_spaces ds_cl ON i_cl.data_space_id = ds_cl.data_space_id
                            JOIN ' + QUOTENAME(@DbName) + N'.sys.partition_schemes ps_cl ON ds_cl.data_space_id = ps_cl.data_space_id
                            WHERE i_nc.object_id = t.object_id 
                            AND i_nc.index_id <> i_cl.index_id
                            AND ps_nc.function_id <> ps_cl.function_id
                        ) THEN 0 ELSE 1 END as is_aligned
                    FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i ON t.object_id = i.object_id
                    WHERE i.type <= 1
                    AND i.data_space_id > 0
                ) AS AlignmentCheck;';

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