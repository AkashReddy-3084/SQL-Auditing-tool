-- Checklist: No redundant/duplicate/overlapping indexes
-- Scope: DATABASE
-- Scoring: 0: >5 redundant indexes found. 1: 1-5 redundant indexes found. 2: 0 found but some databases failed evaluation. 3: 0 found across all evaluated databases.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EvaluatedCount INT = 0;
DECLARE @FailedCount INT = 0;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @EvaluatedCount = 1;
    
    BEGIN TRY
        SET @Sql = N'DECLARE @Cnt INT = 0;
        DECLARE @Det NVARCHAR(MAX) = NULL;
        SELECT @Cnt = COUNT(*),
               @Det = STRING_AGG(QUOTENAME(t.name) + ''.'' + QUOTENAME(i1.name) + '' overlaps '' + QUOTENAME(i2.name), '', '')
        FROM sys.indexes i1
        JOIN sys.indexes i2 ON i1.object_id = i2.object_id AND i1.index_id < i2.index_id
        JOIN sys.tables t ON i1.object_id = t.object_id
        CROSS APPLY (
            SELECT STRING_AGG(c.name, '', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
            FROM sys.index_columns ic
            JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i1.object_id AND ic.index_id = i1.index_id AND ic.is_included_column = 0
        ) k1(keys)
        CROSS APPLY (
            SELECT STRING_AGG(c.name, '', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
            FROM sys.index_columns ic
            JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i2.object_id AND ic.index_id = i2.index_id AND ic.is_included_column = 0
        ) k2(keys)
        WHERE i1.index_id > 0
          AND i2.index_id > 0
          AND k1.keys LIKE k2.keys + ''%'';
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', CASE WHEN @Cnt > 5 THEN 0 WHEN @Cnt > 0 THEN 1 ELSE 3 END, ISNULL(@Det, ''No redundant indexes found''));';
        
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
        SET @FailedCount = 1;
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
        SET @EvaluatedCount = @EvaluatedCount + 1;
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Cnt INT = 0;
            DECLARE @Det NVARCHAR(MAX) = NULL;
            SELECT @Cnt = COUNT(*),
                   @Det = STRING_AGG(QUOTENAME(t.name) + ''.'' + QUOTENAME(i1.name) + '' overlaps '' + QUOTENAME(i2.name), '', '')
            FROM sys.indexes i1
            JOIN sys.indexes i2 ON i1.object_id = i2.object_id AND i1.index_id < i2.index_id
            JOIN sys.tables t ON i1.object_id = t.object_id
            CROSS APPLY (
                SELECT STRING_AGG(c.name, '', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                FROM sys.index_columns ic
                JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = i1.object_id AND ic.index_id = i1.index_id AND ic.is_included_column = 0
            ) k1(keys)
            CROSS APPLY (
                SELECT STRING_AGG(c.name, '', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                FROM sys.index_columns ic
                JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = i2.object_id AND ic.index_id = i2.index_id AND ic.is_included_column = 0
            ) k2(keys)
            WHERE i1.index_id > 0
              AND i2.index_id > 0
              AND k1.keys LIKE k2.keys + ''%'';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', CASE WHEN @Cnt > 5 THEN 0 WHEN @Cnt > 0 THEN 1 ELSE 3 END, ISNULL(@Det, ''No redundant indexes found''));';
            
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
            SET @FailedCount = @FailedCount + 1;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

-- Adjust score if some databases failed but overall score is high
IF @Score = 3 AND @FailedCount > 0
    SET @Score = 2;

SET @Finding = ISNULL((
    SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
    FROM #DbResults
    WHERE Finding IS NOT NULL AND Finding <> ''
), 'No non-compliant findings found');

SET @Result = CASE WHEN @