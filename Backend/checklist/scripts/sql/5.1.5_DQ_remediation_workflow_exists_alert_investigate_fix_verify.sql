-- Checklist: DQ remediation workflow exists (alert → investigate → fix → verify)
-- Scope: DATABASE
-- Scoring: 3: >=4 DQ workflow-related objects found; 2: >=2 objects found; 1: >=1 object found; 0: None found.
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
    SET @Sql = N'
    DECLARE @Matches TABLE (ObjType NVARCHAR(10), ObjName NVARCHAR(128));
    INSERT INTO @Matches
    SELECT 
        CASE WHEN type = ''P'' THEN ''Procedure'' WHEN type = ''U'' THEN ''Table'' ELSE ''Object'' END,
        name
    FROM sys.objects
    WHERE type IN (''P'', ''U'')
      AND (
        name LIKE ''%remediation%'' OR name LIKE ''%dq%'' OR name LIKE ''%quality%'' OR 
        name LIKE ''%alert%'' OR name LIKE ''%investigate%'' OR name LIKE ''%fix%'' OR 
        name LIKE ''%verify%'' OR name LIKE ''%workflow%''
      );
    
    DECLARE @Count INT = (SELECT COUNT(*) FROM @Matches);
    DECLARE @ObjList NVARCHAR(MAX) = (SELECT STRING_AGG(ObjType + ''.'' + ObjName, '', '') FROM @Matches);
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + N''',
        CASE WHEN @Count >= 4 THEN 3 WHEN @Count >= 2 THEN 2 WHEN @Count >= 1 THEN 1 ELSE 0 END,
        ISNULL(@ObjList, ''No DQ workflow artifacts found'')
    );';
    
    EXEC sp_executesql @Sql;
    
    SET @DatabaseQueried = @DbName;
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
            DECLARE @Matches TABLE (ObjType NVARCHAR(10), ObjName NVARCHAR(128));
            INSERT INTO @Matches
            SELECT 
                CASE WHEN type = ''P'' THEN ''Procedure'' WHEN type = ''U'' THEN ''Table'' ELSE ''Object'' END,
                name
            FROM sys.objects
            WHERE type IN (''P'', ''U'')
              AND (
                name LIKE ''%remediation%'' OR name LIKE ''%dq%'' OR name LIKE ''%quality%'' OR 
                name LIKE ''%alert%'' OR name LIKE ''%investigate%'' OR name LIKE ''%fix%'' OR 
                name LIKE ''%verify%'' OR name LIKE ''%workflow%''
              );
            
            DECLARE @Count INT = (SELECT COUNT(*) FROM @Matches);
            DECLARE @ObjList NVARCHAR(MAX) = (SELECT STRING_AGG(ObjType + ''.'' + ObjName, '', '') FROM @Matches);
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + N''',
                CASE WHEN @Count >= 4 THEN 3 WHEN @Count >= 2 THEN 2 WHEN @Count >= 1 THEN 1 ELSE 0 END,
                ISNULL(@ObjList, ''No DQ workflow artifacts found'')
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

    SET @DatabaseQueried = (
        SELECT STRING_AGG(DbName, ', ')
        FROM #DbResults
    );
END

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