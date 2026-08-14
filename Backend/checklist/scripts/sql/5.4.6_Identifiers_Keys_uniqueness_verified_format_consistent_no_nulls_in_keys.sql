-- Checklist: Identifiers / Keys: uniqueness verified; format consistent; no nulls in keys
-- Scope: DATABASE
-- Scoring: 0=No PKs/unique constraints found or all allow nulls; 1=Partial coverage (<50% tables) or inconsistent naming; 2=Most tables (>=50%) have valid non-nullable PKs/unique constraints; 3=All user tables have non-nullable PKs/unique constraints with consistent naming/format.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TotalTables INT = 0;
        DECLARE @ValidTables INT = 0;
        DECLARE @ConsistentNaming INT = 0;

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

        SELECT @ValidTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.indexes i ON t.object_id = i.object_id
        WHERE t.type = ''U'' AND (i.is_primary_key = 1 OR i.is_unique_constraint = 1)
        AND NOT EXISTS (
            SELECT 1 FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND c.is_nullable = 1
        );

        SELECT @ConsistentNaming = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.key_constraints kc ON t.object_id = kc.parent_object_id
        WHERE t.type = ''U'' AND kc.type IN (''PK'', ''UQ'')
        AND (kc.name LIKE ''PK[_]%'' OR kc.name LIKE ''UQ[_]% '');

        DECLARE @DbScore INT = 0;
        IF @TotalTables = 0 SET @DbScore = 3;
        ELSE IF @ValidTables = 0 SET @DbScore = 0;
        ELSE IF @ValidTables < @TotalTables * 0.5 SET @DbScore = 1;
        ELSE IF @ValidTables < @TotalTables SET @DbScore = 2;
        ELSE IF @ConsistentNaming = @ValidTables SET @DbScore = 3;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;