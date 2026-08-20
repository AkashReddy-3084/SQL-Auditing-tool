-- Checklist: CDC / Change Tracking configured and maintained correctly where used
-- Scope: DATABASE
-- Scoring: 3 = CT or CDC enabled and active; 2 = enabled but no tables tracked; 1 = enabled but errors found; 0 = neither enabled nor configured

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
    DECLARE @cdc_enabled BIT, @ct_enabled BIT, @tracked_count INT;
    SELECT @cdc_enabled = is_cdc_enabled, @ct_enabled = is_change_tracking_enabled FROM sys.databases WHERE name = DB_NAME();
    
    SET @tracked_count = 0;
    IF @cdc_enabled = 1
    BEGIN
        SELECT @tracked_count = COUNT(*) FROM sys.cdc_enabled_tables;
    END
    ELSE IF @ct_enabled = 1
    BEGIN
        SELECT @tracked_count = COUNT(*) FROM sys.change_tracking_tables;
    END

    SELECT 
        DB_NAME(),
        CASE 
            WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count > 0 THEN 3
            WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count = 0 THEN 2
            ELSE 0 
        END,
        CASE 
            WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count > 0 THEN ''CDC/CT enabled and active''
            WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count = 0 THEN ''CDC/CT enabled but no tables tracked''
            ELSE ''Neither CDC nor CT enabled''
        END;';
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
            DECLARE @cdc_enabled BIT, @ct_enabled BIT, @tracked_count INT;
            SELECT @cdc_enabled = is_cdc_enabled, @ct_enabled = is_change_tracking_enabled 
            FROM ' + QUOTENAME(@DbName) + N'.sys.databases 
            WHERE name = @p_Db;
            
            SET @tracked_count = 0;
            IF @cdc_enabled = 1
            BEGIN
                SELECT @tracked_count = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.cdc_enabled_tables;
            END
            ELSE IF @ct_enabled = 1
            BEGIN
                SELECT @tracked_count = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.change_tracking_tables;
            END

            SELECT 
                @p_Db,
                CASE 
                    WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count > 0 THEN 3
                    WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count = 0 THEN 2
                    ELSE 0 
                END,
                CASE 
                    WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count > 0 THEN ''CDC/CT enabled and active''
                    WHEN (@cdc_enabled = 1 OR @ct_enabled = 1) AND @tracked_count = 0 THEN ''CDC/CT enabled but no tables tracked''
                    ELSE ''Neither CDC nor CT enabled''
                END;';

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