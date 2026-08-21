-- Checklist: Single source of truth — no duplicate warehouses serving the same purpose
-- Scope: DATABASE
-- Scoring: 3 = No tables duplicated across user databases; 2 = 1-5 duplicated tables; 1 = 6-15 duplicated tables; 0 = >15 duplicated tables.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #AllTables (
    DbName NVARCHAR(128),
    SchemaName NVARCHAR(128),
    TableName NVARCHAR(128)
);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Cross-database iteration not supported
    INSERT INTO #AllTables (DbName, SchemaName, TableName)
    SELECT DB_NAME(), SCHEMA_NAME(schema_id), name
    FROM sys.tables;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (DB_NAME(), 2, 'Cross-database evaluation not supported on Azure SQL Database. Evaluation limited to current database.');
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
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT ''' + @DbName + ''' AS DbName, SCHEMA_NAME(schema_id) AS SchemaName, name AS TableName
            FROM sys.tables;';
            INSERT INTO #AllTables (DbName, SchemaName, TableName)
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

    -- Identify tables that exist in more than one database
    ;WITH DuplicateTables AS (
        SELECT TableName
        FROM #AllTables
        GROUP BY TableName
        HAVING COUNT(DISTINCT DbName) > 1
    ),
    DbDuplicateCounts AS (
        SELECT at.DbName, COUNT(DISTINCT at.TableName) AS DupCount
        FROM #AllTables at
        INNER JOIN DuplicateTables dt ON at.TableName = dt.TableName
        GROUP BY at.DbName
    )
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT
        d.DbName,
        CASE
            WHEN ddc.DupCount IS NULL THEN 3
            WHEN ddc.DupCount <= 5 THEN 2
            WHEN ddc.DupCount <= 15 THEN 1
            ELSE 0
        END AS DbScore,
        CASE
            WHEN ddc.DupCount IS NULL THEN 'No duplicate tables found in this database.'
            ELSE 'Contains ' + CAST(ddc.DupCount AS NVARCHAR(10)) + ' table(s) duplicated across other databases.'
        END AS Finding
    FROM (SELECT DISTINCT DbName FROM #AllTables) d
    LEFT JOIN DbDuplicateCounts ddc ON d.DbName = ddc.DbName;
END

-- Aggregate results
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

DROP TABLE #AllTables;
DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;