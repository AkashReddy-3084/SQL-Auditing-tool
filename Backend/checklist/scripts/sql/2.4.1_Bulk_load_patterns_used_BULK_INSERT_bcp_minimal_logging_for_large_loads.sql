-- Checklist: Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads
-- Scope: DATABASE
-- Scoring: 0: No bulk load patterns detected. 1: 1-2 objects contain bulk patterns. 2: 3-9 objects contain bulk patterns. 3: >=10 objects contain bulk patterns.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @BulkCount INT;
DECLARE @TopObjects NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    
    SET @Sql = N'
    SELECT @BulkCount = COUNT(*),
           @TopObjects = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '') WITHIN GROUP (ORDER BY o.name)
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'',''TF'',''IF'',''FN'',''TR'')
      AND (m.definition LIKE ''%BULK INSERT%''
           OR m.definition LIKE ''%OPENROWSET(BULK%''
           OR m.definition LIKE ''%TABLOCK%''
           OR m.definition LIKE ''%BATCHSIZE%''
           OR m.definition LIKE ''%CHECK_CONSTRAINTS OFF%'');
    ';
    
    EXEC sp_executesql @Sql, N'@BulkCount INT OUTPUT, @TopObjects NVARCHAR(MAX) OUTPUT', @BulkCount OUTPUT, @TopObjects OUTPUT;
    
    SET @BulkCount = ISNULL(@BulkCount, 0);
    
    IF @BulkCount = 0
        SET @Score = 0;
    ELSE IF @BulkCount <= 2
        SET @Score = 1;
    ELSE IF @BulkCount <= 9
        SET @Score = 2;
    ELSE
        SET @Score = 3;
        
    SET @Finding = CASE 
        WHEN @BulkCount = 0 THEN ''No bulk load patterns detected in evaluated objects.''
        ELSE ''Detected '' + CAST(@BulkCount AS NVARCHAR(10)) + '' objects using bulk load patterns (e.g., BULK INSERT, TABLOCK): '' + ISNULL(@TopObjects, ''None listed'')
    END;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @BulkCount = 0;
        SET @TopObjects = NULL;
        
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @BulkCount = COUNT(*),
                   @TopObjects = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '') WITHIN GROUP (ORDER BY o.name)
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'',''TF'',''IF'',''FN'',''TR'')
              AND (m.definition LIKE ''%BULK INSERT%''
                   OR m.definition LIKE ''%OPENROWSET(BULK%''
                   OR m.definition LIKE ''%TABLOCK%''
                   OR m.definition LIKE ''%BATCHSIZE%''
                   OR m.definition LIKE ''%CHECK_CONSTRAINTS OFF%'');
            ';
            EXEC sp_executesql @Sql, N'@BulkCount INT OUTPUT, @TopObjects NVARCHAR(MAX) OUTPUT', @BulkCount OUTPUT, @TopObjects OUTPUT;
            
            IF @BulkCount = 0
                SET @Score = 0;
            ELSE IF @BulkCount <= 2
                SET @Score = 1;
            ELSE IF @BulkCount <= 9
                SET @Score = 2;
            ELSE
                SET @Score = 3;
                
            SET @Finding = CASE 
                WHEN @BulkCount = 0 THEN ''No bulk load patterns detected in evaluated objects.''
                ELSE ''Detected '' + CAST(@BulkCount AS NVARCHAR(10)) + '' objects using bulk load patterns (e.g., BULK INSERT, TABLOCK): '' + ISNULL(@TopObjects, ''None listed'')
            END;
        END TRY
        BEGIN CATCH
            SET @Score = 0;
            SET @Finding = ''Database evaluation failed or insufficient permissions.'';
        END CATCH;

        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;