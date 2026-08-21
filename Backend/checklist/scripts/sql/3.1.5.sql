-- Checklist: No deprecated syntax/features (e.g., old-style joins, TEXT/NTEXT)
-- Scope: DATABASE
-- Scoring: 3 = none; 2 = < 5% affected; 1 = 5-25% affected; 0 = > 25% affected

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
        CASE WHEN DepCount = 0 THEN 3 
             WHEN CAST(DepCount * 100.0 / NULLIF(TotalObjs, 0) AS FLOAT) < 5 THEN 2 
             WHEN CAST(DepCount * 100.0 / NULLIF(TotalObjs, 0) AS FLOAT) < 25 THEN 1 
             ELSE 0 END,
        CASE WHEN DepCount = 0 THEN 'No deprecated syntax/types found'
             ELSE 'Deprecated items found: ' + DepList END
    FROM (
        SELECT 
            (SELECT COUNT(*) FROM sys.objects WHERE type IN ('U', 'P', 'V', 'FN')) as TotalObjs,
            (SELECT COUNT(*) FROM (
                SELECT 1 as Item FROM sys.columns c 
                JOIN sys.tables t ON c.object_id = t.object_id 
                JOIN sys.types ty ON c.user_type_id = ty.user_type_id
                WHERE ty.name IN ('text', 'ntext', 'image')
                UNION ALL
                SELECT 1 FROM sys.sql_modules m 
                JOIN sys.objects o ON m.object_id = o.object_id 
                WHERE m.definition LIKE '% *= %' OR m.definition LIKE '% =* %'
            ) AS t) as DepCount,
            (SELECT STRING_AGG(CAST(Item AS NVARCHAR(MAX)), ', ') FROM (
                SELECT 'Col: ' + QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + '.' + QUOTENAME(c.name) AS Item
                FROM sys.columns c 
                JOIN sys.tables t ON c.object_id = t.object_id 
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                JOIN sys.types ty ON c.user_type_id = ty.user_type_id
                WHERE ty.name IN ('text', 'ntext', 'image')
                UNION ALL
                SELECT 'Module: ' + QUOTENAME(s.name) + '.' + QUOTENAME(o.name)
                FROM sys.sql_modules m 
                JOIN sys.objects o ON m.object_id = o.object_id 
                JOIN sys.schemas s ON o.schema_id = s.schema_id
                WHERE m.definition LIKE '% *= %' OR m.definition LIKE '% =* %'
            ) AS t) as DepList
    ) AS Summary;
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT 
                @p_Db,
                CASE WHEN DepCount = 0 THEN 3 
                     WHEN CAST(DepCount * 100.0 / NULLIF(TotalObjs, 0) AS FLOAT) < 5 THEN 2 
                     WHEN CAST(DepCount * 100.0 / NULLIF(TotalObjs, 0) AS FLOAT) < 25 THEN 1 
                     ELSE 0 END,
                CASE WHEN DepCount = 0 THEN ''No deprecated syntax/types found''
                     ELSE ''Deprecated items found: '' + DepList END
            FROM (
                SELECT 
                    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.objects WHERE type IN (''U'', ''P'', ''V'', ''FN'')) as TotalObjs,
                    (SELECT COUNT(*) FROM (
                        SELECT 1 as Item FROM ' + QUOTENAME(@DbName) + N'.sys.columns c 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON c.user_type_id = ty.user_type_id
                        WHERE ty.name IN (''text'', ''ntext'', ''image'')
                        UNION ALL
                        SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id 
                        WHERE m.definition LIKE ''% *= %'' OR m.definition LIKE ''% =* %''
                    ) AS t) as DepCount,
                    (SELECT STRING_AGG(CAST(Item AS NVARCHAR(MAX)), '', '') FROM (
                        SELECT ''Col: '' + QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''.'' + QUOTENAME(c.name) AS Item
                        FROM ' + QUOTENAME(@DbName) + N'.sys.columns c 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON c.user_type_id = ty.user_type_id
                        WHERE ty.name IN (''text'', ''ntext'', ''image'')
                        UNION ALL
                        SELECT ''Module: '' + QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name)
                        FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id 
                        JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON o.schema_id = s.schema_id
                        WHERE m.definition LIKE ''% *= %'' OR m.definition LIKE ''% =* %''
                    ) AS t) as DepList
            ) AS Summary;';

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