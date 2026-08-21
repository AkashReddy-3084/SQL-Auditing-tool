-- Checklist: Set-based logic used; cursors/WHILE loops avoided except where justified
-- Scope: DATABASE
-- Scoring: 
-- 3: 0 objects found using cursors or WHILE loops.
-- 2: 1-3 objects found.
-- 1: 4-9 objects found.
-- 0: >=10 objects found.
-- NOTE: This script provides automated evidence. Full compliance requires human review to verify if usage is justified.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        SET @Sql = N'
        DECLARE @Count INT;
        DECLARE @ObjList NVARCHAR(MAX);
        
        SELECT @Count = COUNT(*),
               @ObjList = STRING_AGG(o.name, '','') WITHIN GROUP (ORDER BY o.name)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''TF'', ''IF'', ''TR'')
          AND m.definition IS NOT NULL
          AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'');
        
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + @DbName + ''',
            CASE 
                WHEN @Count = 0 THEN 3
                WHEN @Count BETWEEN 1 AND 3 THEN 2
                WHEN @Count BETWEEN 4 AND 9 THEN 1
                ELSE 0
            END,
            CASE WHEN @Count = 0 THEN ''No non-compliant objects found'' ELSE @ObjList END
        );
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Count INT;
            DECLARE @ObjList NVARCHAR(MAX);
            
            SELECT @Count = COUNT(*),
                   @ObjList = STRING_AGG(o.name, '','') WITHIN GROUP (ORDER BY o.name)
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''TF'', ''IF'', ''TR'')
              AND m.definition IS NOT NULL
              AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'');
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + ''',
                CASE 
                    WHEN @Count = 0 THEN 3
                    WHEN @Count BETWEEN 1 AND 3 THEN 2
                    WHEN @Count BETWEEN 4 AND 9 THEN 1
                    ELSE 0
                END,
                CASE WHEN @Count = 0 THEN ''No non-compliant objects found'' ELSE @ObjList END
            );
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;