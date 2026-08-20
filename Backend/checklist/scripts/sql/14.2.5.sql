-- Checklist: Columnstore health maintained (rowgroup quality, tuple mover) where used
-- Scope: DATABASE
-- Scoring: 3 = No Columnstore indexes or 0% fragmented; 2 = < 10% fragmented rowgroups; 1 = 10-25% fragmented; 0 = > 25% fragmented or error.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: Current DB only
    BEGIN TRY
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        SELECT 
            DB_NAME(),
            CASE 
                WHEN COUNT(*) = 0 THEN 3 
                WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) = 0 THEN 3
                WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) < 0.1 THEN 2
                WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) <= 0.25 THEN 1
                ELSE 0 
            END,
            CASE 
                WHEN COUNT(*) = 0 THEN 'No Columnstore indexes found'
                ELSE 'FragRowGroups: ' + CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS VARCHAR) + ' of ' + CAST(COUNT(*) AS VARCHAR)
            END
        FROM sys.dm_db_column_store_row_group_physical_stats
        WHERE state_desc = 'CLOSED';
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (DB_NAME(), 0, 'Evaluation failed: ' + ERROR_MESSAGE());
    END CATCH
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
            -- DMVs are not database-scoped via 3-part names. 
            -- We must switch context or use the database_id filter within the DMV.
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; 
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT 
                DB_NAME(),
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) = 0 THEN 3
                    WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) < 0.1 THEN 2
                    WHEN (CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0)) <= 0.25 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No Columnstore indexes found''
                    ELSE ''FragRowGroups: '' + CAST(SUM(CASE WHEN total_rows < 1024 THEN 1 ELSE 0 END) AS VARCHAR) + '' of '' + CAST(COUNT(*) AS VARCHAR)
                END
            FROM sys.dm_db_column_store_row_group_physical_stats
            WHERE state_desc = ''CLOSED'';';

            EXEC sp_executesql @Sql;
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