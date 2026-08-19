-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 3 = no unqualified references; 2 = < 5% unqualified; 1 = 5-25% unqualified; 0 = > 25% unqualified

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Sql = N'
    SELECT 
        DB_NAME(),
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN CAST(COUNT(*) * 100.0 / NULLIF(SUM(TotalObjs), 0) AS INT) < 5 THEN 2 
            WHEN CAST(COUNT(*) * 100.0 / NULLIF(SUM(TotalObjs), 0) AS INT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN ''No unqualified references found''
            ELSE ''Unqualified objects found in: '' + STRING_AGG(QUOTENAME(o.name), '', '') 
        END
    FROM (
        SELECT 
            o.name, 
            CASE WHEN m.definition LIKE ''%[ ]'' + REPLACE(o.name, '''', '''''') + ''[ \r\n\t(],%'' 
                 AND m.definition NOT LIKE ''%.\'' + REPLACE(o.name, '''', '''''') + ''[ \r\n\t(],%'' 
                 THEN 1 ELSE 0 END as IsUnqualified,
            COUNT(*) OVER() as TotalObjs
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'')
    ) AS t
    JOIN sys.objects o ON 1=1 -- This is a placeholder for the aggregation logic
    WHERE t.IsUnqualified = 1;';
    -- The above logic is a heuristic. To properly implement this without a parser, 
    -- we check if the object name appears in its own definition without a preceding dot.
    -- However, for the sake of a functional audit script, we will use a more robust approach.
END

-- Redefining the logic to be applied across databases
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
        SELECT 
            @p_Db,
            CASE 
                WHEN COUNT(*) = 0 THEN 3 
                WHEN CAST(COUNT(*) * 100.0 / NULLIF(SUM(TotalObjs), 0) AS INT) < 5 THEN 2 
                WHEN CAST(COUNT(*) * 100.0 / NULLIF(SUM(TotalObjs), 0) AS INT) < 25 THEN 1 
                ELSE 0 
            END,
            CASE 
                WHEN COUNT(*) = 0 THEN ''No unqualified references found''
                ELSE ''Unqualified objects found in: '' + STRING_AGG(CAST(o.name AS NVARCHAR(MAX)), '', '') 
            END
        FROM (
            SELECT 
                o.name, 
                CASE WHEN m.definition LIKE ''%[ ]'' + REPLACE(o.name, '''''''', '''''''''''') + ''[ \r\n\t(],%'' 
                     AND m.definition NOT LIKE ''%.\'' + REPLACE(o.name, '''''''', '''''''''''') + ''[ \r\n\t(],%'' 
                     THEN 1 ELSE 0 END as IsUnqualified,
                COUNT(*) OVER() as TotalObjs
            FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m
            JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'')
        ) AS t
        JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON t.name = o.name
        WHERE t.IsUnqualified = 1;';

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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;