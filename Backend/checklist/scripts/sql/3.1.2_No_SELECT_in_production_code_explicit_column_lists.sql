-- Checklist: No SELECT * in production code; explicit column lists
-- Scope: DATABASE
-- Scoring: 3: No SELECT * found. 2: No SELECT * found but some modules are encrypted/inaccessible. 1: 1-5 modules contain SELECT *. 0: >5 modules contain SELECT *.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @DatabaseQueried = @DbName;
    
    SET @Sql = N'
    DECLARE @MatchCount INT = 0;
    DECLARE @EncryptedCount INT = 0;
    DECLARE @ObjList NVARCHAR(MAX) = '';
    
    SELECT @MatchCount = COUNT(*),
           @EncryptedCount = SUM(CASE WHEN o.is_encrypted = 1 THEN 1 ELSE 0 END),
           @ObjList = STRING_AGG(o.name, '','')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'')
      AND (m.definition LIKE ''%SELECT *%'' OR m.definition LIKE ''%SELECT  *%'');
      
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + ''',
        CASE 
            WHEN @MatchCount = 0 AND @EncryptedCount > 0 THEN 2
            WHEN @MatchCount = 0 THEN 3
            WHEN @MatchCount BETWEEN 1 AND 5 THEN 1
            ELSE 0
        END,
        CASE 
            WHEN @MatchCount = 0 AND @EncryptedCount > 0 THEN ''No SELECT * found, but '' + CAST(@EncryptedCount AS NVARCHAR) + '' encrypted module(s) could not be verified.''
            WHEN @MatchCount = 0 THEN ''No SELECT * found in any user-defined modules.''
            ELSE ''Found SELECT * in: '' + @ObjList
        END
    );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate online user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @MatchCount INT = 0;
            DECLARE @EncryptedCount INT = 0;
            DECLARE @ObjList NVARCHAR(MAX) = '';
            
            SELECT @MatchCount = COUNT(*),
                   @EncryptedCount = SUM(CASE WHEN o.is_encrypted = 1 THEN 1 ELSE 0 END),
                   @ObjList = STRING_AGG(o.name, '','')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.is_ms_shipped = 0
              AND o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'')
              AND (m.definition LIKE ''%SELECT *%'' OR m.definition LIKE ''%SELECT  *%'');
              
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + ''',
                CASE 
                    WHEN @MatchCount = 0 AND @EncryptedCount > 0 THEN 2
                    WHEN @MatchCount = 0 THEN 3
                    WHEN @MatchCount BETWEEN 1 AND 5 THEN 1
                    ELSE 0
                END,
                CASE 
                    WHEN @MatchCount = 0 AND @EncryptedCount > 0 THEN ''No SELECT * found, but '' + CAST(@EncryptedCount AS NVARCHAR) + '' encrypted module(s) could not be verified.''
                    WHEN @MatchCount = 0 THEN ''No SELECT * found in any user-defined modules.''
                    ELSE ''Found SELECT * in: '' + @ObjList
                END
            );
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed or inaccessible');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL((
    SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
    FROM #DbResults
    WHERE Finding IS NOT NULL AND Finding <> ''
), 'No non-compliant findings found');

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;