-- Checklist: Set-based operations preferred over row-by-row processing
-- Scope: DATABASE
-- Scoring: 3 = no row-by-row patterns; 2 = < 5% of modules; 1 = 5-25% of modules; 0 = > 25% of modules

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
            WHEN COUNT(CASE WHEN m.definition LIKE '%CURSOR%' OR m.definition LIKE '%FETCH NEXT%' OR m.definition LIKE '%WHILE%' THEN 1 END) = 0 THEN 3
            WHEN CAST(COUNT(CASE WHEN m.definition LIKE '%CURSOR%' OR m.definition LIKE '%FETCH NEXT%' OR m.definition LIKE '%WHILE%' THEN 1 END) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 5 THEN 2
            WHEN CAST(COUNT(CASE WHEN m.definition LIKE '%CURSOR%' OR m.definition LIKE '%FETCH NEXT%' OR m.definition LIKE '%WHILE%' THEN 1 END) * 100.0 / NULLIF(COUNT(*), 0) AS INT) < 25 THEN 1
            ELSE 0
        END,
        ISNULL('Row-by-row patterns found in: ' + (
            SELECT STRING_AGG(QUOTENAME(s.name) + '.' + QUOTENAME(o.name), ', ')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE m.definition LIKE '%CURSOR%' OR m.definition LIKE '%FETCH NEXT%' OR m.definition LIKE '%WHILE%'
        ), 'No row-by-row patterns found')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id;
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
            DECLARE @cnt INT, @total INT, @list NVARCHAR(MAX);
            SELECT @total = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules;
            
            SELECT @list = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name), '', '')
            FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m
            JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id
            JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON o.schema_id = s.schema_id
            WHERE m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%FETCH NEXT%'' OR m.definition LIKE ''%WHILE%'';

            SELECT @cnt = COUNT(*) 
            FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m
            WHERE m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%FETCH NEXT%'' OR m.definition LIKE ''%WHILE%'';

            SELECT 
                @p_Db,
                CASE 
                    WHEN @cnt = 0 THEN 3
                    WHEN CAST(@cnt * 100.0 / NULLIF(@total, 0) AS INT) < 5 THEN 2
                    WHEN CAST(@cnt * 100.0 / NULLIF(@total, 0) AS INT) < 25 THEN 1
                    ELSE 0
                END,
                ISNULL(''Row-by-row patterns found in: '' + @list, ''No row-by-row patterns found'');';

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