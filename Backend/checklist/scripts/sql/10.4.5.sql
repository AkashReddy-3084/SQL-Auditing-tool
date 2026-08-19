-- Checklist: Log/rowcount reconciliation captured per ETL run
-- Scope: DATABASE
-- Scoring: 3 = reconciliation tables/columns found with data; 2 = tables/columns found but no recent data; 1 = minimal naming matches; 0 = no evidence found.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database path
    SET @Sql = N'
    DECLARE @LocalScore INT = 0;
    DECLARE @LocalFinding NVARCHAR(MAX) = ''No reconciliation artifacts found'';
    
    IF EXISTS (SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%rowcount%'' OR c.name LIKE ''%recon%'' OR t.name LIKE ''%etl_log%'' OR t.name LIKE ''%audit_log%'')
    BEGIN
        SET @LocalScore = 2;
        SET @LocalFinding = ''Reconciliation artifacts found but no data verified'';
        
        -- Check for data in those tables (Score 3)
        -- We use a dynamic check to see if any of the identified tables have rows
        IF EXISTS (
            SELECT 1 FROM sys.tables t 
            WHERE (t.name LIKE ''%etl_log%'' OR t.name LIKE ''%audit_log%'' OR EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND (c.name LIKE ''%rowcount%'' OR c.name LIKE ''%recon%'')))
            AND EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = t.object_id AND p.rows > 0)
        )
        BEGIN
            SET @LocalScore = 3;
            SET @LocalFinding = ''Reconciliation artifacts found with data'';
        END
    END
    ELSE IF EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%log%'' OR name LIKE ''%audit%'')
    BEGIN
        SET @LocalScore = 1;
        SET @LocalFinding = ''Minimal naming matches found'';
    END

    SELECT DB_NAME(), @LocalScore, @LocalFinding;';
    
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
            DECLARE @LocalScore INT = 0;
            DECLARE @LocalFinding NVARCHAR(MAX) = ''No reconciliation artifacts found'';
            
            IF EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%rowcount%'' OR c.name LIKE ''%recon%'' OR t.name LIKE ''%etl_log%'' OR t.name LIKE ''%audit_log%'')
            BEGIN
                SET @LocalScore = 2;
                SET @LocalFinding = ''Reconciliation artifacts found but no data verified'';
                
                IF EXISTS (
                    SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t 
                    WHERE (t.name LIKE ''%etl_log%'' OR t.name LIKE ''%audit_log%'' OR EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c WHERE c.object_id = t.object_id AND (c.name LIKE ''%rowcount%'' OR c.name LIKE ''%recon%'')))
                    AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.partitions p WHERE p.object_id = t.object_id AND p.rows > 0)
                )
                BEGIN
                    SET @LocalScore = 3;
                    SET @LocalFinding = ''Reconciliation artifacts found with data'';
                END
            END
            ELSE IF EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%log%'' OR name LIKE ''%audit%'')
            BEGIN
                SET @LocalScore = 1;
                SET @LocalFinding = ''Minimal naming matches found'';
            END

            SELECT @p_Db, @LocalScore, @LocalFinding;';

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