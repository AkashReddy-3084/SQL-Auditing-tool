-- Checklist: Historical SLA compliance tracked and reported
-- Scope: DATABASE
-- Scoring: 0: No proxy evidence found. 1: Limited proxy evidence (1-2 relevant objects). 2: Strong proxy evidence (3+ relevant objects indicating tracking/reporting). 3: Fully compliant (reserved; not applicable for this process-based check; max caps at 2).
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
    SET @Sql = N'DECLARE @ObjCount INT = 0;
    DECLARE @ObjList NVARCHAR(MAX) = '''';
    SELECT @ObjCount = COUNT(*), @ObjList = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name), '','')
    FROM sys.objects o
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.type IN (''U'',''V'',''P'')
      AND (o.name LIKE ''%sla%'' OR o.name LIKE ''%compliance%'');
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + REPLACE(@DbName, '''', '''''') + ''',
            CASE WHEN @ObjCount >= 3 THEN 2 WHEN @ObjCount >= 1 THEN 1 ELSE 0 END,
            ISNULL(@ObjList, ''No SLA/compliance tracking objects found''));';
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
            DECLARE @ObjCount INT = 0;
            DECLARE @ObjList NVARCHAR(MAX) = '''';
            SELECT @ObjCount = COUNT(*), @ObjList = STRING_AGG(QUOTENAME(s.name) + ''.'' + QUOTENAME(o.name), '','')
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN (''U'',''V'',''P'')
              AND (o.name LIKE ''%sla%'' OR o.name LIKE ''%compliance%'');
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''',
                    CASE WHEN @ObjCount >= 3 THEN 2 WHEN @ObjCount >= 1 THEN 1 ELSE 0 END,
                    ISNULL(@ObjList, ''No SLA/compliance tracking objects found''));';
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