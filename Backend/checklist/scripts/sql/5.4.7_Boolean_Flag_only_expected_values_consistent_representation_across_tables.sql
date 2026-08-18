-- Checklist: Boolean / Flag: only expected values; consistent representation across tables
-- Scope: DATABASE
-- Scoring: 3=All candidates have CHECK constraints; 2=>75% constrained or consistent data; 1=25-75% constrained or inconsistent data; 0=<25% constrained or no candidates.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

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

-- Per-database evaluation logic
DECLARE @EvalSql NVARCHAR(MAX) = N'
DECLARE @Candidates TABLE (
    SchemaName sysname,
    TableName sysname,
    ColumnName sysname,
    DataType sysname,
    HasCheckConstraint bit,
    DistinctValues nvarchar(max)
);

INSERT INTO @Candidates (SchemaName, TableName, ColumnName, DataType, HasCheckConstraint)
SELECT TOP 100
    s.name,
    t.name,
    c.name,
    tp.name,
    CASE WHEN cc.object_id IS NOT NULL THEN 1 ELSE 0 END
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.types tp ON c.user_type_id = tp.user_type_id
LEFT JOIN sys.check_constraints cc ON cc.parent_object_id = t.object_id AND cc.parent_column_id = c.column_id
WHERE tp.name IN (''bit'', ''tinyint'', ''char'', ''varchar'', ''nchar'', ''nvarchar'')
  AND c.max_length <= 2
  AND (
      c.name LIKE ''%flag%'' OR c.name LIKE ''%is_%'' OR c.name LIKE ''%has_%'' OR c.name LIKE ''%bool%''
      OR tp.name = ''bit''
  )
ORDER BY s.name, t.name, c.name;

-- Sample distinct values for unconstrained columns
DECLARE @ColCursor CURSOR;
DECLARE @Sch sysname, @Tbl sysname, @Col sysname, @Typ sysname, @HasCC bit, @DistinctVals nvarchar(max);

SET @ColCursor = CURSOR LOCAL FAST_FORWARD FOR
SELECT SchemaName, TableName, ColumnName, DataType, HasCheckConstraint FROM @Candidates WHERE HasCheckConstraint = 0;

OPEN @ColCursor;
FETCH NEXT FROM @ColCursor INTO @Sch, @Tbl, @Col, @Typ, @HasCC;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N''SELECT @Vals = STRING_AGG(CAST([col] AS NVARCHAR(128)), '','') FROM (SELECT DISTINCT TOP 10 [col] FROM '' + QUOTENAME(@Sch) + ''.'' + QUOTENAME(@Tbl) + '') AS sub;'';
        SET @Sql = REPLACE(@Sql, ''[col]'', QUOTENAME(@Col));
        EXEC sp_executesql @Sql, N''@Vals NVARCHAR(MAX) OUTPUT'', @Vals = @DistinctVals OUTPUT;
        UPDATE @Candidates SET DistinctValues = @DistinctVals WHERE SchemaName = @Sch AND TableName = @Tbl AND ColumnName = @Col;
    END TRY
    BEGIN CATCH
        UPDATE @Candidates SET DistinctValues = ''Error sampling'' WHERE SchemaName = @Sch AND TableName = @Tbl AND ColumnName = @Col;
    END CATCH;
    FETCH NEXT FROM @ColCursor INTO @Sch, @Tbl, @Col, @Typ, @HasCC;
END
CLOSE @ColCursor;
DEALLOCATE @ColCursor;

-- Calculate score and finding for this database
DECLARE @TotalCols INT = (SELECT COUNT(*) FROM @Candidates);
DECLARE @ConstrainedCols INT = (SELECT COUNT(*) FROM @Candidates WHERE HasCheckConstraint = 1);
DECLARE @InconsistentCols INT = (SELECT COUNT(*) FROM @Candidates WHERE HasCheckConstraint = 0 AND DistinctValues LIKE ''%Error%'' OR (DistinctValues IS NOT NULL AND LEN(DistinctValues) > 20));

DECLARE @DbScore INT;
DECLARE @DbFinding NVARCHAR(MAX);

IF @TotalCols = 0
BEGIN
    SET @DbScore = 0;
    SET @DbFinding = ''No boolean/flag columns identified'';
END
ELSE
BEGIN
    DECLARE @PctConstrained FLOAT = CAST(@ConstrainedCols AS FLOAT) / @TotalCols;
    
    IF @PctConstrained >= 1.0
        SET @DbScore = 3;
    ELSE IF @PctConstrained >= 0.75
        SET @DbScore = 2;
    ELSE IF @PctConstrained >= 0.25
        SET @DbScore = 1;
    ELSE
        SET @DbScore = 0;

    -- Build finding
    DECLARE @ConstrainedList NVARCHAR(MAX) = (SELECT STRING_AGG(QUOTENAME(SchemaName) + ''.'' + QUOTENAME(TableName) + ''.'' + QUOTENAME(ColumnName), '','') FROM @Candidates WHERE HasCheckConstraint = 1);
    DECLARE @UnconstrainedList NVARCHAR(MAX) = (SELECT STRING_AGG(QUOTENAME(SchemaName) + ''.'' + QUOTENAME(TableName) + ''.'' + QUOTENAME(ColumnName) + '' ('' + ISNULL(DistinctValues, ''No constraint'') + '')'', '','') FROM @Candidates WHERE HasCheckConstraint = 0);
    
    SET @DbFinding = ''Total: '' + CAST(@TotalCols AS NVARCHAR) + ''; Constrained: '' + CAST(@ConstrainedCols AS NVARCHAR) + ''; Unconstrained: '' + CAST(@TotalCols - @ConstrainedCols AS NVARCHAR) + ''; '' +
        CASE WHEN @ConstrainedList IS NOT NULL THEN ''Constrained: '' + @ConstrainedList + ''; '' ELSE '''' END +
        CASE WHEN @UnconstrainedList IS NOT NULL THEN ''Unconstrained: '' + @UnconstrainedList ELSE '''' END;
END;

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (''DB_PLACEHOLDER'', @DbScore, @DbFinding);
';

-- Replace placeholder with actual DB name during execution
SET @EvalSql = REPLACE(@EvalSql, '''DB_PLACEHOLDER''', ''' + QUOTENAME(@DbName) + '''');

IF @IsAzureSQLDB = 1
BEGIN
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    BEGIN TRY
        EXEC sp_executesql @EvalSql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
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
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @EvalSql;
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

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;