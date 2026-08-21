-- Checklist: Incremental load implemented where applicable (watermark / CDC / Change Tracking)
-- Scope: DATABASE
-- Scoring: 3 = CDC or CT enabled; 2 = Watermark columns found; 1 = Minimal evidence; 0 = No evidence found

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
    SET @Sql = N'
    DECLARE @s INT = 0;
    DECLARE @f NVARCHAR(MAX) = ''No incremental load evidence found'';
    
    IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 1
    BEGIN
        SET @s = 3; SET @f = ''CDC Enabled'';
    END
    ELSE IF EXISTS (SELECT 1 FROM sys.columns WHERE name LIKE ''%last_modified%'' OR name LIKE ''%updated_at%'' OR name LIKE ''%sys_change_version%'' )
    BEGIN
        SET @s = 2; SET @f = ''Watermark columns found'';
    END
    
    SELECT DB_NAME(), @s, @f;';
    
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
            -- Use dynamic SQL to switch context to the target database
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @s INT = 0;
            DECLARE @f NVARCHAR(MAX) = ''No incremental load evidence found'';
            
            IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 1
            BEGIN
                SET @s = 3; SET @f = ''CDC Enabled'';
            END
            ELSE IF EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            BEGIN
                SET @s = 3; SET @f = ''Change Tracking Enabled'';
            END
            ELSE IF EXISTS (SELECT 1 FROM sys.columns WHERE name LIKE ''%last_modified%'' OR name LIKE ''%updated_at%'' OR name LIKE ''%sys_change_version%'' )
            BEGIN
                SET @s = 2; SET @f = ''Watermark columns found'';
            END
            
            SELECT DB_NAME(), @s, @f;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
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