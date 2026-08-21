-- Checklist: Conformed dimensions shared across facts (no duplicate versions)
-- Scope: DATABASE
-- Scoring: 3=No duplicates, 2=1-2 duplicates, 1=3-5 duplicates, 0=>5 duplicates

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

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
    DECLARE @DupCount INT = 0;
    DECLARE @DupList NVARCHAR(MAX) = N'';

    SELECT @DupCount = COUNT(*),
           @DupList = STRING_AGG(DupInfo, N'' | '')
    FROM (
        SELECT t.name AS DimName,
               STRING_AGG(s.name + N''.'' + t.name, N'') AS DupInfo
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE N''dim%'' OR t.name LIKE N''Dim%''
        GROUP BY t.name
        HAVING COUNT(*) > 1
    ) d;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        N''' + REPLACE(@DbName, '''', '''''') + N''',
        CASE WHEN @DupCount = 0 THEN 3
             WHEN @DupCount <= 2 THEN 2
             WHEN @DupCount <= 5 THEN 1
             ELSE 0 END,
        CASE WHEN @DupCount = 0 THEN N''No duplicate dimension versions found.''
             ELSE N''Duplicate dimensions: '' + ISNULL(@DupList, N''None'') END
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
            SET @Sql = N'
            DECLARE @DupCount INT = 0;
            DECLARE @DupList NVARCHAR(MAX) = N'';

            SELECT @DupCount = COUNT(*),
                   @DupList = STRING_AGG(DupInfo, N'' | '')
            FROM (
                SELECT t.name AS DimName,
                       STRING_AGG(s.name + N''.'' + t.name, N'') AS DupInfo
                FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.name LIKE N''dim%'' OR t.name LIKE N''Dim%''
                GROUP BY t.name
                HAVING COUNT(*) > 1
            ) d;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                N''' + REPLACE(@DbName, '''', '''''') + N''',
                CASE WHEN @DupCount = 0 THEN 3
                     WHEN @DupCount <= 2 THEN 2
                     WHEN @DupCount <= 5 THEN 1
                     ELSE 0 END,
                CASE WHEN @DupCount = 0 THEN N''No duplicate dimension versions found.''
                     ELSE N''Duplicate dimensions: '' + ISNULL(@DupList, N''None'') END
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

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;