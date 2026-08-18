-- Checklist: No duplicate grain in fact tables
-- Scope: DATABASE
-- Scoring: 3: All fact tables have PK/Unique constraints and zero duplicates. 2: All fact tables have zero duplicates, but lack PK/Unique constraints. 1: Duplicates found in some fact tables. 0: Duplicates found in all fact tables, or fact tables exist but grain cannot be verified.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbList (DbName NVARCHAR(128));
CREATE TABLE #DbResults (DbName NVARCHAR(128), DbScore INT, Finding NVARCHAR(MAX));
CREATE TABLE #FactTables (DbName NVARCHAR(128), SchemaName NVARCHAR(128), TableName NVARCHAR(128), HasGrainConstraint BIT, KeyCols NVARCHAR(MAX), DupCount INT);

-- Platform-specific database list
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
END

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #DbList;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Identify fact tables and their grain constraints
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #FactTables (DbName, SchemaName, TableName, HasGrainConstraint, KeyCols, DupCount)
        SELECT
            ''' + @DbName + N''' AS DbName,
            s.name AS SchemaName,
            t.name AS TableName,
            CASE WHEN i.index_id IS NOT NULL THEN 1 ELSE 0 END AS HasGrainConstraint,
            STRING_AGG(c.name, '' , '') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyCols,
            0 AS DupCount
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND (i.is_primary_key = 1 OR i.is_unique = 1)
        LEFT JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        LEFT JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE s.name = ''Fact'' OR t.name LIKE ''Fact%'' OR t.name LIKE ''F_%''
        GROUP BY s.name, t.name, i.index_id;';
        EXEC sp_executesql @Sql;

        -- Check duplicates for tables with identified grain constraints
        DECLARE @SchemaName NVARCHAR(128), @TableName NVARCHAR(128), @KeyCols NVARCHAR(MAX), @DupCount INT;
        DECLARE fact_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName, TableName, KeyCols FROM #FactTables WHERE DbName = @DbName AND HasGrainConstraint = 1;
        OPEN fact_cursor;
        FETCH NEXT FROM fact_cursor INTO @SchemaName, @TableName, @KeyCols;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @DupCount = COUNT(*) FROM (
                SELECT ' + @KeyCols + N', COUNT(*) as cnt
                FROM ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) + N'
                GROUP BY ' + @KeyCols + N'
                HAVING COUNT(*) > 1
            ) dup;';
            EXEC sp_executesql @Sql, N'@DupCount INT OUTPUT', @DupCount OUTPUT;
            UPDATE #FactTables SET DupCount = @DupCount WHERE DbName = @DbName AND SchemaName = @SchemaName AND TableName = @TableName;
            FETCH NEXT FROM fact_cursor INTO @SchemaName, @TableName, @KeyCols;
        END
        CLOSE fact_cursor;
        DEALLOCATE fact_cursor;

        -- Calculate per-database score and finding
        DECLARE @TotalFact INT = (SELECT COUNT(*) FROM #FactTables WHERE DbName = @DbName);
        DECLARE @WithGrain INT = (SELECT COUNT(*) FROM #FactTables WHERE DbName = @DbName AND HasGrainConstraint = 1);
        DECLARE @WithDups INT = (SELECT COUNT(*) FROM #FactTables WHERE DbName = @DbName AND DupCount > 0);
        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @TotalFact = 0
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = 'No fact tables found';
        END
        ELSE IF @WithDups > 0
        BEGIN
            SET @DbScore = CASE WHEN @WithDups = @TotalFact THEN 0 ELSE 1 END;
            SET @DbFinding = (SELECT STRING_AGG(TableName + '' ('' + CAST(DupCount AS NVARCHAR) + '' dups)'', '''') FROM #FactTables WHERE DbName = @DbName AND DupCount > 0);
        END
        ELSE IF @WithGrain = @TotalFact
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = 'All fact tables have grain constraints and no duplicates';
        END
        ELSE
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = 'No duplicates found, but some fact tables lack grain constraints: ' + (SELECT STRING_AGG(TableName, '''') FROM #FactTables WHERE DbName = @DbName AND HasGrainConstraint = 0);
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed: ' + ERROR_MESSAGE());
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN '