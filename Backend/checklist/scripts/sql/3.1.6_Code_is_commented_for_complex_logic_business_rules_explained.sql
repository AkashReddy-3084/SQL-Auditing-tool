-- Checklist: Code is commented for complex logic; business rules explained
-- Scope: DATABASE
-- Scoring: 3: >=90% of complex objects have comments; 2: 50-89%; 1: 1-49%; 0: 0% or no complex objects found.

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

CREATE TABLE #EvalResults (
    TotalComplex INT,
    CommentedCount INT,
    NonCompliantObjects NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    WITH ComplexModules AS (
        SELECT o.name AS ObjectName, o.type_desc, m.definition
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.is_ms_shipped = 0
          AND LEN(m.definition) > 500
    ),
    CommentedModules AS (
        SELECT ObjectName, type_desc
        FROM ComplexModules
        WHERE definition LIKE ''%--%'' OR definition LIKE ''%/*%''
    ),
    NonCompliant AS (
        SELECT ObjectName
        FROM ComplexModules c
        LEFT JOIN CommentedModules cm ON c.ObjectName = cm.ObjectName AND c.type_desc = cm.type_desc
        WHERE cm.ObjectName IS NULL
    )
    SELECT
        COUNT(*) AS TotalComplex,
        SUM(CASE WHEN cm.ObjectName IS NOT NULL THEN 1 ELSE 0 END) AS CommentedCount,
        ISNULL((SELECT STRING_AGG(ObjectName, '','') FROM NonCompliant), '''') AS NonCompliantObjects
    FROM ComplexModules c
    LEFT JOIN CommentedModules cm ON c.ObjectName = cm.ObjectName AND c.type_desc = cm.type_desc;
    ';
    INSERT INTO #EvalResults EXEC(@Sql);
    
    DECLARE @Total INT = (SELECT TotalComplex FROM #EvalResults);
    DECLARE @Commented INT = (SELECT CommentedCount FROM #EvalResults);
    DECLARE @NonComp NVARCHAR(MAX) = (SELECT NonCompliantObjects FROM #EvalResults);
    
    IF @Total = 0
        SET @Score = 3;
    ELSE BEGIN
        DECLARE @Pct FLOAT = (@Commented * 100.0) / @Total;
        IF @Pct >= 90 SET @Score = 3;
        ELSE IF @Pct >= 50 SET @Score = 2;
        ELSE IF @Pct >= 1 SET @Score = 1;
        ELSE SET @Score = 0;
    END
    
    SET @Finding = CAST(@Commented AS NVARCHAR) + ' of ' + CAST(@Total AS NVARCHAR) + ' complex objects contain comments';
    IF @Score < 2 AND @NonComp <> ''
        SET @Finding = @Finding + '; Non-compliant: ' + @NonComp;
        
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        TRUNCATE TABLE #EvalResults;
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        WITH ComplexModules AS (
            SELECT o.name AS ObjectName, o.type_desc, m.definition
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.is_ms_shipped = 0
              AND LEN(m.definition) > 500
        ),
        CommentedModules AS (
            SELECT ObjectName, type_desc
            FROM ComplexModules
            WHERE definition LIKE ''%--%'' OR definition LIKE ''%/*%''
        ),
        NonCompliant AS (
            SELECT ObjectName
            FROM ComplexModules c
            LEFT JOIN CommentedModules cm ON c.ObjectName = cm.ObjectName AND c.type_desc = cm.type_desc
            WHERE cm.ObjectName IS NULL
        )
        SELECT
            COUNT(*) AS TotalComplex,
            SUM(CASE WHEN cm.ObjectName IS NOT NULL THEN 1 ELSE 0 END) AS CommentedCount,
            ISNULL((SELECT STRING_AGG(ObjectName, '','') FROM NonCompliant), '''') AS NonCompliantObjects
        FROM ComplexModules c
        LEFT JOIN CommentedModules cm ON c.ObjectName = cm.ObjectName AND c.type_desc = cm.type_desc;
        ';
        
        BEGIN TRY
            INSERT INTO #EvalResults EXEC(@Sql);
            
            DECLARE @Total INT = (SELECT TotalComplex FROM #EvalResults);
            DECLARE @Commented INT = (SELECT CommentedCount FROM #EvalResults);
            DECLARE @NonComp NVARCHAR(MAX) = (SELECT NonCompliantObjects FROM #EvalResults);
            
            IF @Total = 0
                SET @Score = 3;
            ELSE BEGIN
                DECLARE @Pct FLOAT = (@Commented * 100.0) / @Total;
                IF @Pct >= 90 SET @Score = 3;
                ELSE IF @Pct >= 50 SET @Score = 2;
                ELSE IF @Pct >= 1 SET @Score = 1;
                ELSE SET @Score = 0;
            END
            
            SET @Finding = CAST(@Commented AS NVARCHAR) + ' of ' + CAST(@Total AS NVARCHAR) + ' complex objects contain comments';
            IF @Score < 2 AND @NonComp <> ''
                SET @Finding = @Finding + '; Non-compliant: ' + @NonComp;
                
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
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
DROP TABLE #EvalResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;