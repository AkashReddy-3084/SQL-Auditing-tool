-- Checklist: Reusable/templated ETL components (no copy-paste per table)
-- Scope: DATABASE
-- Scoring: 3 = generic procedures used by multiple objects; 2 = some parameterization; 1 = minimal modularity; 0 = no reusable patterns found.

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
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%sp_executesql%' AND m.definition LIKE '%@%') AND (SELECT COUNT(*) FROM sys.sql_expression_dependencies WHERE referenced_id > 0) > 5 THEN 3
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%sp_executesql%' OR m.definition LIKE '%@%') THEN 2
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%@%') THEN 1
             ELSE 0 
           END,
           CASE 
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%sp_executesql%' AND m.definition LIKE '%@%') AND (SELECT COUNT(*) FROM sys.sql_expression_dependencies WHERE referenced_id > 0) > 5 THEN 'Generic templated procedures detected'
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%sp_executesql%' OR m.definition LIKE '%@%') THEN 'Some parameterization found'
             WHEN EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE '%@%') THEN 'Minimal modularity detected'
             ELSE 'No reusable ETL patterns found' 
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
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%sp_executesql%'' AND m.definition LIKE ''%@%'' ) AND (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies WHERE referenced_id > 0) > 5 THEN 3
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%sp_executesql%'' OR m.definition LIKE ''%@%'' ) THEN 2
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%@%'' ) THEN 1
                  ELSE 0 
                END,
                CASE 
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%sp_executesql%'' AND m.definition LIKE ''%@%'' ) AND (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies WHERE referenced_id > 0) > 5 THEN ''Generic templated procedures detected''
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%sp_executesql%'' OR m.definition LIKE ''%@%'' ) THEN ''Some parameterization found''
                  WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m JOIN ' + QUOTENAME(@DbName) + N'.sys.procedures p ON m.object_id = p.object_id WHERE m.definition LIKE ''%@%'' ) THEN ''Minimal modularity detected''
                  ELSE ''No reusable ETL patterns found'' 
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;