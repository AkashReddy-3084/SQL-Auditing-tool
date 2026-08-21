-- Checklist: Aggregate consistency: detail sums equal aggregate totals
-- Scope: DATABASE
-- Scoring: 3=No aggregate objects detected; 2=Aggregate objects detected with clear dependencies or aggregation logic; 1=Aggregate objects detected but missing dependencies/logic; 0=Broken dependencies or inconsistency markers. Proxy caps at 2.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        SET @Sql = N'
        DECLARE @AggCount INT = 0;
        DECLARE @DepCount INT = 0;
        DECLARE @ObjList NVARCHAR(MAX) = '''';

        SELECT @AggCount = COUNT(*), @DepCount = SUM(CASE WHEN HasDep = 1 THEN 1 ELSE 0 END)
        FROM (
            SELECT t.name, CASE WHEN EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d WHERE d.object_id = t.object_id) THEN 1 ELSE 0 END AS HasDep
            FROM sys.tables t
            WHERE t.name LIKE ''%agg%'' OR t.name LIKE ''%sum%'' OR t.name LIKE ''%total%'' OR t.name LIKE ''%fact%''
            UNION ALL
            SELECT v.name, CASE WHEN OBJECT_DEFINITION(v.object_id) LIKE ''%GROUP BY%'' THEN 1 ELSE 0 END AS HasDep
            FROM sys.views v
            WHERE v.name LIKE ''%agg%'' OR v.name LIKE ''%sum%'' OR v.name LIKE ''%total%''
        ) agg;

        SELECT @ObjList = STRING_AGG(name, '', '') FROM (
            SELECT name FROM sys.tables WHERE name LIKE ''%agg%'' OR name LIKE ''%sum%'' OR name LIKE ''%total%'' OR name LIKE ''%fact%''
            UNION ALL
            SELECT name FROM sys.views WHERE name LIKE ''%agg%'' OR name LIKE ''%sum%'' OR name LIKE ''%total%''
        ) o;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + @DbName + N''',
            CASE 
                WHEN @AggCount = 0 THEN 3
                WHEN @DepCount = @AggCount THEN 2
                WHEN @DepCount > 0 THEN 1
                ELSE 0
            END,
            CASE 
                WHEN @AggCount = 0 THEN ''No aggregate objects detected''
                WHEN @DepCount = @AggCount THEN ''Aggregate objects detected with dependencies/logic: '' + @ObjList
                WHEN @DepCount > 0 THEN ''Aggregate objects detected but missing dependencies/logic: '' + @ObjList
                ELSE ''Aggregate objects detected with no dependencies: '' + @ObjList
            END
        );';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            DECLARE @AggCount INT = 0;
            DECLARE @DepCount INT = 0;
            DECLARE @ObjList NVARCHAR(MAX) = '''';

            SELECT @AggCount = COUNT(*), @DepCount = SUM(CASE WHEN HasDep = 1 THEN 1 ELSE 0 END)
            FROM (
                SELECT t.name, CASE WHEN EXISTS (SELECT 1 FROM sys.sql_expression_dependencies d WHERE d.object_id = t.object_id) THEN 1 ELSE 0 END AS HasDep
                FROM sys.tables t
                WHERE t.name LIKE ''%agg%'' OR t.name LIKE ''%sum%'' OR t.name LIKE ''%total%'' OR t.name LIKE ''%fact%''
                UNION ALL
                SELECT v.name, CASE WHEN OBJECT_DEFINITION(v.object_id) LIKE ''%GROUP BY%'' THEN 1 ELSE 0 END AS HasDep
                FROM sys.views v
                WHERE v.name LIKE ''%agg%'' OR v.name LIKE ''%sum%'' OR v.name LIKE ''%total%''
            ) agg;

            SELECT @ObjList = STRING_AGG(name, '', '') FROM (
                SELECT name FROM sys.tables WHERE name LIKE ''%agg%'' OR name LIKE ''%sum%'' OR name LIKE ''%total%'' OR name LIKE ''%fact%''
                UNION ALL
                SELECT name FROM sys.views WHERE name LIKE ''%agg%'' OR name LIKE ''%sum%'' OR name LIKE ''%total%''
            ) o;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + N''',
                CASE 
                    WHEN @AggCount = 0 THEN 3
                    WHEN @DepCount = @AggCount THEN 2
                    WHEN @DepCount > 0 THEN 1
                    ELSE 0
                END,
                CASE 
                    WHEN @AggCount = 0 THEN ''No aggregate objects detected''
                    WHEN @DepCount = @AggCount THEN ''Aggregate objects detected with dependencies/logic: '' + @ObjList
                    WHEN @DepCount > 0 THEN ''Aggregate objects detected but missing dependencies/logic: '' + @ObjList
                    ELSE ''Aggregate objects detected with no dependencies: '' + @ObjList
                END
            );';
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

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
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