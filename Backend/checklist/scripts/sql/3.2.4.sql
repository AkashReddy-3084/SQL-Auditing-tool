-- Checklist: Views used appropriately (no deeply nested view chains that hide cost)
-- Scope: DATABASE
-- Scoring: 3 = no views nested > 3 levels; 2 = some views nested 4-6 levels; 1 = views nested > 6 levels; 0 = database not readable

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
    WITH ViewHierarchy AS (
        SELECT 
            o.object_id, 
            o.name AS ObjectName, 
            0 AS Depth
        FROM sys.views o
        UNION ALL
        SELECT 
            o.object_id, 
            o.name, 
            vh.Depth + 1
        FROM sys.views o
        JOIN sys.sql_expression_dependencies d ON d.referencing_id = o.object_id
        JOIN ViewHierarchy vh ON d.referenced_id = vh.object_id
        WHERE vh.Depth < 20
    ),
    MaxDepths AS (
        SELECT ObjectName, MAX(Depth) as MaxDepth 
        FROM ViewHierarchy 
        GROUP BY ObjectName
    )
    SELECT 
        DB_NAME(),
        CASE WHEN MAX(MaxDepth) <= 3 THEN 3 WHEN MAX(MaxDepth) <= 6 THEN 2 ELSE 1 END,
        CASE WHEN MAX(MaxDepth) <= 3 THEN ''No deeply nested views found''
             ELSE ''Deeply nested views found: '' + STRING_AGG(QUOTENAME(ObjectName), '', '') 
             FROM MaxDepths WHERE MaxDepth > 3 END
    FROM MaxDepths;';
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
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
            WITH ViewHierarchy AS (
                SELECT 
                    o.object_id, 
                    o.name AS ObjectName, 
                    0 AS Depth
                FROM ' + QUOTENAME(@DbName) + N'.sys.views o
                UNION ALL
                SELECT 
                    o.object_id, 
                    o.name, 
                    vh.Depth + 1
                FROM ' + QUOTENAME(@DbName) + N'.sys.views o
                JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_expression_dependencies d ON d.referencing_id = o.object_id
                JOIN ViewHierarchy vh ON d.referenced_id = vh.object_id
                WHERE vh.Depth < 20
            ),
            MaxDepths AS (
                SELECT ObjectName, MAX(Depth) as MaxDepth 
                FROM ViewHierarchy 
                GROUP BY ObjectName
            )
            SELECT 
                @p_Db,
                CASE WHEN MAX(MaxDepth) <= 3 THEN 3 WHEN MAX(MaxDepth) <= 6 THEN 2 ELSE 1 END,
                CASE WHEN MAX(MaxDepth) <= 3 THEN ''No deeply nested views found''
                     ELSE ''Deeply nested views found: '' + (SELECT STRING_AGG(QUOTENAME(ObjectName), '', '') FROM MaxDepths WHERE MaxDepth > 3) END
            FROM MaxDepths;';

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