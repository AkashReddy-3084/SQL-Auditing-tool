-- Checklist: Unit tests exist for critical transformation logic (e.g., tSQLt)
-- Scope: DATABASE
-- Scoring: 3 = tSQLt schema found; 2 = custom 'test_' objects found; 1 = minimal evidence; 0 = no evidence found

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
             WHEN EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'tSQLt') THEN 3 
             WHEN EXISTS (SELECT 1 FROM sys.objects WHERE name LIKE 'test_%' OR name LIKE '%_test') THEN 2 
             WHEN EXISTS (SELECT 1 FROM sys.objects WHERE name LIKE '%test%' OR name LIKE '%unit%') THEN 1
             ELSE 0 
           END,
           CASE 
             WHEN EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'tSQLt') THEN 'tSQLt framework detected' 
             WHEN EXISTS (SELECT 1 FROM sys.objects WHERE name LIKE 'test_%' OR name LIKE '%_test') THEN 'Custom test objects found' 
             WHEN EXISTS (SELECT 1 FROM sys.objects WHERE name LIKE '%test%' OR name LIKE '%unit%') THEN 'Minimal evidence of tests found'
             ELSE 'No unit test objects or tSQLt schema found' 
           END;
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
                CASE 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.schemas WHERE name = ''tSQLt'') THEN 3 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.objects WHERE name LIKE ''test_%'' OR name LIKE ''%_test'') THEN 2 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.objects WHERE name LIKE ''%test%'' OR name LIKE ''%unit%'') THEN 1
                  ELSE 0 
                END,
                CASE 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.schemas WHERE name = ''tSQLt'') THEN ''tSQLt framework detected'' 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.objects WHERE name LIKE ''test_%'' OR name LIKE ''%_test'') THEN ''Custom test objects found'' 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.objects WHERE name LIKE ''%test%'' OR name LIKE ''%unit%'') THEN ''Minimal evidence of tests found''
                  ELSE ''No unit test objects or tSQLt schema found'' 
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