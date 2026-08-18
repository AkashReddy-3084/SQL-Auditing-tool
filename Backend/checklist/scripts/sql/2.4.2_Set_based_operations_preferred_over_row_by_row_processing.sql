-- Checklist: Set-based operations preferred over row-by-row processing
-- Scope: DATABASE
-- Scoring: 3=No RBAR objects found, 2=1 object found, 1=2-3 objects found, 0=>=4 objects found

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

CREATE TABLE #RbarCheck (RbarCount INT, RbarList NVARCHAR(MAX));

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SELECT 
        COUNT(*) AS RbarCount,
        STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, CHAR(44) + CHAR(32)) AS RbarList
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
      AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'' OR m.definition LIKE ''%FETCH%'');';
      
    INSERT INTO #RbarCheck EXEC sp_executesql @Sql;
    
    DECLARE @Cnt INT = (SELECT ISNULL(MAX(RbarCount), 0) FROM #RbarCheck);
    DECLARE @List NVARCHAR(MAX) = (SELECT ISNULL(MAX(RbarList), '''') FROM #RbarCheck);
    
    DECLARE @DbScore INT;
    SET @DbScore = CASE 
        WHEN @Cnt = 0 THEN 3
        WHEN @Cnt = 1 THEN 2
        WHEN @Cnt BETWEEN 2 AND 3 THEN 1
        ELSE 0
    END;
    
    DECLARE @DbFinding NVARCHAR(MAX);
    SET @DbFinding = CASE 
        WHEN @Cnt = 0 THEN ''No row-by-row (RBAR) patterns detected in ETL objects.''
        ELSE ''RBAR patterns (CURSOR/WHILE/FETCH) found in: '' + ISNULL(@List, ''None'')
    END;
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE -- SQL Server / Azure SQL MI
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
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT 
                COUNT(*) AS RbarCount,
                STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, CHAR(44) + CHAR(32)) AS RbarList
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
              AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'' OR m.definition LIKE ''%FETCH%'');';

            TRUNCATE TABLE #RbarCheck;
            INSERT INTO #RbarCheck EXEC sp_executesql @Sql;

            DECLARE @Cnt INT = (SELECT ISNULL(MAX(RbarCount), 0) FROM #RbarCheck);
            DECLARE @List NVARCHAR(MAX) = (SELECT ISNULL(MAX(RbarList), '''') FROM #RbarCheck);

            DECLARE @DbScore INT;
            SET @DbScore = CASE 
                WHEN @Cnt = 0 THEN 3
                WHEN @Cnt = 1 THEN 2
                WHEN @Cnt BETWEEN 2 AND 3 THEN 1
                ELSE 0
            END;

            DECLARE @DbFinding NVARCHAR(MAX);
            SET @DbFinding = CASE 
                WHEN @Cnt = 0 THEN ''No row-by-row (RBAR) patterns detected in ETL objects.''
                ELSE ''RBAR patterns (CURSOR/WHILE/FETCH) found in: '' + ISNULL(@List, ''None'')
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, @DbScore, @DbFinding);
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, ''Database evaluation failed'');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, '', '')
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
    ''No non-compliant findings found''
);

SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;

DROP TABLE #DbResults;
DROP TABLE #RbarCheck;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;