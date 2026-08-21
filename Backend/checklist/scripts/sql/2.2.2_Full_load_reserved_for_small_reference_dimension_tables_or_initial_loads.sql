-- Checklist: Full load reserved for small reference/dimension tables or initial loads
-- Scope: DATABASE
-- Scoring: 3=No large tables (>1M rows) use full load patterns; 2=1-2 large tables use full loads; 1=3-4 large tables use full loads; 0=>=5 large tables use full loads.

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @FullLoadTables TABLE (TableName NVARCHAR(128), RowCount BIGINT, ProcName NVARCHAR(128));

    INSERT INTO @FullLoadTables
    SELECT DISTINCT
        t.name,
        SUM(ps.rows),
        p.name
    FROM sys.procedures p
    JOIN sys.sql_modules sm ON p.object_id = sm.object_id
    JOIN sys.tables t ON sm.definition LIKE ''%'' + QUOTENAME(t.name) + ''%''
    JOIN sys.dm_db_partition_stats ps ON t.object_id = ps.object_id AND ps.index_id IN (0,1)
    WHERE sm.definition IS NOT NULL
      AND (sm.definition LIKE ''%TRUNCATE TABLE%'' OR sm.definition LIKE ''%DELETE FROM%'')
    GROUP BY t.name, p.name, SUM(ps.rows)
    HAVING SUM(ps.rows) > 1000000;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT ''' + @DbName + ''',
        CASE
            WHEN COUNT(*) = 0 THEN 3
            WHEN COUNT(*) = 1 THEN 2
            WHEN COUNT(*) <= 4 THEN 1
            ELSE 0
        END,
        ISNULL(STUFF((SELECT '', '' + TableName FROM @FullLoadTables FOR XML PATH(''), TYPE).value(''.'',''NVARCHAR(MAX)''), 1, 2, ''''), ''No non-compliant objects found'')
    FROM @FullLoadTables;
    ';
    EXEC sp_executesql @Sql;
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
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @FullLoadTables TABLE (TableName NVARCHAR(128), RowCount BIGINT, ProcName NVARCHAR(128));

            INSERT INTO @FullLoadTables
            SELECT DISTINCT
                t.name,
                SUM(ps.rows),
                p.name
            FROM sys.procedures p
            JOIN sys.sql_modules sm ON p.object_id = sm.object_id
            JOIN sys.tables t ON sm.definition LIKE ''%'' + QUOTENAME(t.name) + ''%''
            JOIN sys.dm_db_partition_stats ps ON t.object_id = ps.object_id AND ps.index_id IN (0,1)
            WHERE sm.definition IS NOT NULL
              AND (sm.definition LIKE ''%TRUNCATE TABLE%'' OR sm.definition LIKE ''%DELETE FROM%'')
            GROUP BY t.name, p.name, SUM(ps.rows)
            HAVING SUM(ps.rows) > 1000000;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''',
                CASE
                    WHEN COUNT(*) = 0 THEN 3
                    WHEN COUNT(*) = 1 THEN 2
                    WHEN COUNT(*) <= 4 THEN 1
                    ELSE 0
                END,
                ISNULL(STUFF((SELECT '', '' + TableName FROM @FullLoadTables FOR XML PATH(''), TYPE).value(''.'',''NVARCHAR(MAX)''), 1, 2, ''''), ''No non-compliant objects found'')
            FROM @FullLoadTables;
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