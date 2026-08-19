-- Checklist: Bad/rejected rows routed to a quarantine/error table
-- Scope: DATABASE
-- Scoring: 3 = quarantine tables exist and are referenced in code; 2 = quarantine tables exist; 1 = error columns exist; 0 = no evidence found

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
             WHEN EXISTS (SELECT 1 FROM sys.tables t CROSS JOIN sys.sql_modules m WHERE (t.name LIKE '%error%' OR t.name LIKE '%reject%' OR t.name LIKE '%quarantine%') AND m.definition LIKE '%' + t.name + '%') THEN 3
             WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%error%' OR name LIKE '%reject%' OR name LIKE '%quarantine%') THEN 2
             WHEN EXISTS (SELECT 1 FROM sys.columns WHERE name LIKE '%error%' OR name LIKE '%reject%') THEN 1
             ELSE 0 
           END,
           CASE 
             WHEN EXISTS (SELECT 1 FROM sys.tables t CROSS JOIN sys.sql_modules m WHERE (t.name LIKE '%error%' OR t.name LIKE '%reject%' OR t.name LIKE '%quarantine%') AND m.definition LIKE '%' + t.name + '%') THEN 'Quarantine tables found and referenced in code'
             WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%error%' OR name LIKE '%reject%' OR name LIKE '%quarantine%') THEN 'Quarantine tables found: ' + ISNULL((SELECT STRING_AGG(name, ', ') FROM sys.tables WHERE name LIKE '%error%' OR name LIKE '%reject%' OR name LIKE '%quarantine%'), '')
             WHEN EXISTS (SELECT 1 FROM sys.columns WHERE name LIKE '%error%' OR name LIKE '%reject%') THEN 'No quarantine tables, but error-related columns found'
             ELSE 'No quarantine/error tables or columns found'
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
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t CROSS JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%quarantine%'') AND m.definition LIKE ''%'' + t.name + ''%'') THEN 3
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%error%'' OR name LIKE ''%reject%'' OR name LIKE ''%quarantine%'') THEN 2
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns WHERE name LIKE ''%error%'' OR name LIKE ''%reject%'') THEN 1
                  ELSE 0 
                END,
                CASE 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t CROSS JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%quarantine%'') AND m.definition LIKE ''%'' + t.name + ''%'') THEN ''Quarantine tables found and referenced in code''
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%error%'' OR name LIKE ''%reject%'' OR name LIKE ''%quarantine%'') THEN ''Quarantine tables found: '' + ISNULL((SELECT STRING_AGG(name, '', '') FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''%error%'' OR name LIKE ''%reject%'' OR name LIKE ''%quarantine%''), '''')
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns WHERE name LIKE ''%error%'' OR name LIKE ''%reject%'') THEN ''No quarantine tables, but error-related columns found''
                  ELSE ''No quarantine/error tables or columns found''
                END';

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

IF NOT EXISTS (SELECT 1 FROM #DbResults)
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Score = 0;
    SET @Finding = 'No database found to be queried';
    SET @Result = 'Fail';
END
ELSE
BEGIN
    SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
    SET @Score = (SELECT MIN(DbScore) FROM #DbResults);
    SET @Finding = (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults);
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
END

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;