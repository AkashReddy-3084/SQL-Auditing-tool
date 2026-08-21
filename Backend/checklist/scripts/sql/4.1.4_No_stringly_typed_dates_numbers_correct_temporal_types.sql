-- Checklist: No stringly-typed dates/numbers; correct temporal types
-- Scope: DATABASE
-- Scoring: 3=0 non-compliant cols, 2=1-5, 1=6-20, 0=>20

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
    DECLARE @Count INT;
    DECLARE @Cols NVARCHAR(MAX);
    
    SELECT @Count = COUNT(*),
           @Cols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
    FROM sys.columns c
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.types tp ON c.user_type_id = tp.user_type_id
    WHERE tp.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
      AND (
        LOWER(c.name) LIKE ''%date%'' OR LOWER(c.name) LIKE ''%dt%'' OR LOWER(c.name) LIKE ''%time%'' OR LOWER(c.name) LIKE ''%timestamp%''
        OR LOWER(c.name) LIKE ''%num%'' OR LOWER(c.name) LIKE ''%number%'' OR LOWER(c.name) LIKE ''%amount%'' OR LOWER(c.name) LIKE ''%price%''
        OR LOWER(c.name) LIKE ''%qty%'' OR LOWER(c.name) LIKE ''%quantity%'' OR LOWER(c.name) LIKE ''%count%'' OR LOWER(c.name) LIKE ''%total%''
        OR LOWER(c.name) LIKE ''%balance%'' OR LOWER(c.name) LIKE ''%rate%'' OR LOWER(c.name) LIKE ''%percent%'' OR LOWER(c.name) LIKE ''%pct%''
      )
      AND t.is_ms_shipped = 0;
      
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + QUOTENAME(@DbName) + ''',
        CASE 
            WHEN @Count = 0 THEN 3
            WHEN @Count BETWEEN 1 AND 5 THEN 2
            WHEN @Count BETWEEN 6 AND 20 THEN 1
            ELSE 0
        END,
        ISNULL(@Cols, ''No non-compliant objects found'')
    );
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @Count INT;
            DECLARE @Cols NVARCHAR(MAX);
            
            SELECT @Count = COUNT(*),
                   @Cols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.types tp ON c.user_type_id = tp.user_type_id
            WHERE tp.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
              AND (
                LOWER(c.name) LIKE ''%date%'' OR LOWER(c.name) LIKE ''%dt%'' OR LOWER(c.name) LIKE ''%time%'' OR LOWER(c.name) LIKE ''%timestamp%''
                OR LOWER(c.name) LIKE ''%num%'' OR LOWER(c.name) LIKE ''%number%'' OR LOWER(c.name) LIKE ''%amount%'' OR LOWER(c.name) LIKE ''%price%''
                OR LOWER(c.name) LIKE ''%qty%'' OR LOWER(c.name) LIKE ''%quantity%'' OR LOWER(c.name) LIKE ''%count%'' OR LOWER(c.name) LIKE ''%total%''
                OR LOWER(c.name) LIKE ''%balance%'' OR LOWER(c.name) LIKE ''%rate%'' OR LOWER(c.name) LIKE ''%percent%'' OR LOWER(c.name) LIKE ''%pct%''
              )
              AND t.is_ms_shipped = 0;
              
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + QUOTENAME(@DbName) + ''',
                CASE 
                    WHEN @Count = 0 THEN 3
                    WHEN @Count BETWEEN 1 AND 5 THEN 2
                    WHEN @Count BETWEEN 6 AND 20 THEN 1
                    ELSE 0
                END,
                ISNULL(@Cols, ''No non-compliant objects found'')
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
          AND Finding <> 'No non-compliant objects found'
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