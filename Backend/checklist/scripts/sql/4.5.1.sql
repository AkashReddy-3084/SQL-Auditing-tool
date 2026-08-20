-- Checklist: Primary keys defined on all tables
-- Scope: DATABASE
-- Scoring: 3 = no tables missing PKs; 2 = < 5% missing PKs; 1 = < 25% missing PKs; 0 = >= 25% missing PKs

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
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN CAST(COUNT(*) * 100.0 / NULLIF((SELECT COUNT(*) FROM sys.tables), 0) AS FLOAT) < 5 THEN 2
            WHEN CAST(COUNT(*) * 100.0 / NULLIF((SELECT COUNT(*) FROM sys.tables), 0) AS FLOAT) < 25 THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN 'No tables missing PKs'
            ELSE 'Tables missing PKs: ' + (SELECT STRING_AGG(QUOTENAME(s.name) + '.' + QUOTENAME(t.name), ', ') 
                                           FROM sys.tables t 
                                           JOIN sys.schemas s ON t.schema_id = s.schema_id 
                                           WHERE NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1))
        END
    FROM sys.tables t
    WHERE NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
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
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN CAST(COUNT(*) * 100.0 / NULLIF((SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables), 0) AS FLOAT) < 5 THEN 2
                    WHEN CAST(COUNT(*) * 100.0 / NULLIF((SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables), 0) AS FLOAT) < 25 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No tables missing PKs''
                    ELSE ''Tables missing PKs: '' + (SELECT STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name), '', '') 
                                                   FROM ' + QUOTENAME(@DbName) + N'.sys.tables t 
                                                   JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id 
                                                   WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1))
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
                WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);';

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

SELECT @DatabaseQueried = ISNULL(STRING_AGG(DbName, ', '), 'None') FROM #DbResults;
SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;
SELECT @Finding = ISNULL(STRING_AGG(DbName + ': ' + Finding, '; '), 'No database found to be queried') FROM #DbResults;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;