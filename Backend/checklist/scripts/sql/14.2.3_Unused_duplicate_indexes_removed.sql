-- Checklist: Unused/duplicate indexes removed
-- Scope: DATABASE
-- Scoring: 0: >10 unused/duplicate indexes. 1: 1-10 unused/duplicate indexes. 2: 1-3 unused/duplicate indexes. 3: No unused or duplicate indexes found.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

SET @Sql = N'
    DECLARE @UnusedCount INT = 0;
    DECLARE @DuplicateCount INT = 0;
    DECLARE @UnusedList NVARCHAR(MAX) = '';
    DECLARE @DuplicateList NVARCHAR(MAX) = '';

    SELECT @UnusedCount = COUNT(*),
           @UnusedList = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '')
    FROM sys.indexes i
    JOIN sys.tables t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
    WHERE i.type_desc IN (''clustered'', ''nonclustered'')
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND (us.user_updates > 0 AND (us.user_seeks + us.user_scans + us.user_lookups) = 0);

    ;WITH IndexKeys AS (
        SELECT i.object_id, i.index_id, i.name, s.name AS schema_name, t.name AS table_name,
               STRING_AGG(c.name, '','' ORDER BY ic.key_ordinal) AS key_columns
        FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE i.type_desc IN (''clustered'', ''nonclustered'')
          AND i.is_primary_key = 0
          AND i.is_unique_constraint = 0
        GROUP BY i.object_id, i.index_id, i.name, s.name, t.name
    )
    SELECT @DuplicateCount = COUNT(*),
           @DuplicateList = STRING_AGG(schema_name + ''.'' + table_name + ''.'' + name, '', '')
    FROM (
        SELECT schema_name, table_name, name, key_columns,
               ROW_NUMBER() OVER(PARTITION BY object_id, key_columns ORDER BY index_id) AS rn
        FROM IndexKeys
    ) dup
    WHERE rn > 1;

    DECLARE @TotalIssues INT = @UnusedCount + @DuplicateCount;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';

    IF @TotalIssues = 0 SET @DbScore = 3;
    ELSE IF @TotalIssues <= 3 SET @DbScore = 2;
    ELSE IF @TotalIssues <= 10 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    IF @TotalIssues > 0
        SET @DbFinding = ''Unused: '' + ISNULL(@UnusedList, ''None'') + ''; Duplicate: '' + ISNULL(@DuplicateList, ''None'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@TargetDb, @DbScore, @DbFinding);
';

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @DatabaseQueried = @DbName;
    EXEC sp_executesql @Sql, N'@TargetDb NVARCHAR(128)', @TargetDb = @DbName;
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @Sql;
            EXEC sp_executesql @Sql, N'@TargetDb NVARCHAR(128)', @TargetDb = @DbName;
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
SET @Result = CASE WHEN @Score >= 2 THEN