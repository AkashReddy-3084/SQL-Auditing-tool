-- Checklist: Deduplication verified — no duplicate business keys after load
-- Scope: DATABASE
-- Scoring: 3: All business-key columns have UNIQUE constraints/indexes. 2: >80% covered or no business-key columns found (proxy evidence). 1: 20-80% covered. 0: <20% covered.
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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT ''' + @DbName + ''',
           CASE 
               WHEN TotalCount = 0 THEN 2
               WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 1.0 THEN 3
               WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 0.8 THEN 2
               WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 0.2 THEN 1
               ELSE 0
           END,
           CASE 
               WHEN TotalCount = 0 THEN ''No business key columns identified; manual verification required.''
               WHEN NonCompliantList IS NULL OR NonCompliantList = '' THEN ''All business key columns protected by UNIQUE constraints/indexes.''
               ELSE ''Missing UNIQUE constraints on: '' + NonCompliantList
           END
    FROM (
        WITH BkCols AS (
            SELECT t.name AS TableName, c.name AS ColName, c.column_id, t.object_id
            FROM sys.tables t
            JOIN sys.columns c ON t.object_id = c.object_id
            WHERE t.is_ms_shipped = 0
              AND (c.name LIKE ''%BusinessKey%'' OR c.name LIKE ''%NaturalKey%'' OR c.name LIKE ''%SourceKey%'' OR c.name LIKE ''%ExternalID%'' OR c.name LIKE ''%BK%'')
        ),
        UniqueCols AS (
            SELECT DISTINCT ic.object_id, ic.column_id
            FROM sys.index_columns ic
            JOIN sys.indexes i ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.is_unique = 1
        )
        SELECT
            SUM(CASE WHEN uc.object_id IS NOT NULL THEN 1 ELSE 0 END) AS UniqueCount,
            COUNT(*) AS TotalCount,
            STRING_AGG(CASE WHEN uc.object_id IS NULL THEN b.TableName + ''.'' + b.ColName ELSE NULL END, '', '') AS NonCompliantList
        FROM BkCols b
        LEFT JOIN UniqueCols uc ON b.object_id = uc.object_id AND b.column_id = uc.column_id
    ) AS Data;
    ';
    EXEC sp_executesql @Sql;
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''',
                   CASE 
                       WHEN TotalCount = 0 THEN 2
                       WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 1.0 THEN 3
                       WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 0.8 THEN 2
                       WHEN CAST(UniqueCount AS FLOAT) / TotalCount >= 0.2 THEN 1
                       ELSE 0
                   END,
                   CASE 
                       WHEN TotalCount = 0 THEN ''No business key columns identified; manual verification required.''
                       WHEN NonCompliantList IS NULL OR NonCompliantList = '' THEN ''All business key columns protected by UNIQUE constraints/indexes.''
                       ELSE ''Missing UNIQUE constraints on: '' + NonCompliantList
                   END
            FROM (
                WITH BkCols AS (
                    SELECT t.name AS TableName, c.name AS ColName, c.column_id, t.object_id
                    FROM sys.tables t
                    JOIN sys.columns c ON t.object_id = c.object_id
                    WHERE t.is_ms_shipped = 0
                      AND (c.name LIKE ''%BusinessKey%'' OR c.name LIKE ''%NaturalKey%'' OR c.name LIKE ''%SourceKey%'' OR c.name LIKE ''%ExternalID%'' OR c.name LIKE ''%BK%'')
                ),
                UniqueCols AS (
                    SELECT DISTINCT ic.object_id, ic.column_id
                    FROM sys.index_columns ic
                    JOIN sys.indexes i ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                    WHERE i.is_unique = 1
                )
                SELECT
                    SUM(CASE WHEN uc.object_id IS NOT NULL THEN 1 ELSE 0 END) AS UniqueCount,
                    COUNT(*) AS TotalCount,
                    STRING_AGG(CASE WHEN uc.object_id IS NULL THEN b.TableName + ''.'' + b.ColName ELSE NULL END, '', '') AS NonCompliantList
                FROM BkCols b
                LEFT JOIN UniqueCols uc ON b.object_id = uc.object_id AND b.column_id = uc.column_id
            ) AS Data;
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