-- Checklist: Transparent Data Encryption (TDE) enabled for encryption at rest
-- Scope: DATABASE
-- Scoring: 3 = all user databases encrypted; 2 = >80% encrypted; 1 = 1-80% encrypted; 0 = none encrypted or error

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
        CASE WHEN encryption_state = 3 THEN 3 ELSE 0 END,
        CASE WHEN encryption_state = 3 THEN 'TDE Enabled' ELSE 'TDE Disabled (state=' + CAST(encryption_state AS NVARCHAR(1)) + ')' END
    FROM sys.dm_database_encryption_list
    WHERE database_id = DB_ID();
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
            -- Use QUOTENAME to handle database names and pass the ID to the DMV
            SET @Sql = N'SELECT 
                CASE WHEN encryption_state = 3 THEN 3 ELSE 0 END,
                CASE WHEN encryption_state = 3 THEN ''TDE Enabled'' ELSE ''TDE Disabled (state='' + CAST(encryption_state AS NVARCHAR(1)) + '')'' END
                FROM sys.dm_database_encryption_list
                WHERE database_id = DB_ID()';

            -- We must execute the query in the context of the specific database to get the correct DB_ID() 
            -- or use the database name in the DMV filter.
            -- Since sys.dm_database_encryption_list is a server-level DMV, we can filter by database_id.
            
            DECLARE @CurrentDbId INT = DB_ID(@DbName);
            DECLARE @DynamicSql NVARCHAR(MAX) = N'SELECT 
                CASE WHEN encryption_state = 3 THEN 3 ELSE 0 END,
                CASE WHEN encryption_state = 3 THEN ''TDE Enabled'' ELSE ''TDE Disabled (state='' + CAST(encryption_state AS NVARCHAR(1)) + '')'' END
                FROM sys.dm_database_encryption_list
                WHERE database_id = ' + CAST(@CurrentDbId AS NVARCHAR(10));

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @DynamicSql;
            
            IF @@ROWCOUNT = 0
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (@DbName, 0, 'TDE Disabled (no entry in encryption list)');
            END
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
DECLARE @EncryptedDBs INT = (SELECT COUNT(*) FROM #DbResults WHERE DbScore = 3);

IF @TotalDBs = 0
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
    
    -- Scoring based on proportion
    SET @Score = CASE 
        WHEN @EncryptedDBs = @TotalDBs THEN 3
        WHEN CAST(@EncryptedDBs AS FLOAT) / NULLIF(@TotalDBs, 0) > 0.8 THEN 2
        WHEN @EncryptedDBs > 0 THEN 1
        ELSE 0 
    END;

    SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No evidence found');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;