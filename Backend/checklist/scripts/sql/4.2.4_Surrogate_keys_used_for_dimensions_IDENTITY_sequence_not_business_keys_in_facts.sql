-- Checklist: Surrogate keys used for dimensions (IDENTITY/sequence), not business keys in facts
-- Scope: DATABASE
-- Scoring: 0=Non-compliant/No evidence, 1=Partial (facts use business keys), 2=Mostly compliant (gaps in FKs/coverage), 3=Fully compliant
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        SET @Sql = N'DECLARE @DimTotal INT, @DimSurrogate INT, @FactTotal INT, @FactSurrogateFK INT, @FactBusinessFK INT, @DbScore INT;
        SELECT @DimTotal = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''dim[_]%'';
        SELECT @FactTotal = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''fact[_]%'';

        SELECT @DimSurrogate = COUNT(DISTINCT t.object_id)
        FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
        JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON t.object_id = c.object_id
        WHERE t.name LIKE ''dim[_]%''
          AND (EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = t.object_id AND ic.column_id = c.column_id)
               OR EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.default_constraints dc WHERE dc.parent_object_id = t.object_id AND dc.parent_column_id = c.column_id AND dc.definition LIKE ''%NEXT VALUE FOR%''));

        SELECT @FactSurrogateFK = COUNT(DISTINCT fk.parent_object_id)
        FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk
        JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
        JOIN ' + QUOTENAME(@DbName) + N'.sys.tables dim ON fkc.referenced_object_id = dim.object_id
        JOIN ' + QUOTENAME(@DbName) + N'.sys.columns dimCol ON fkc.referenced_object_id = dimCol.object_id AND fkc.referenced_column_id = dimCol.column_id
        WHERE fk.parent_object_id IN (SELECT object_id FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''fact[_]%''')
          AND dim.name LIKE ''dim[_]%''
          AND (EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = dim.object_id AND ic.column_id = dimCol.column_id)
               OR EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.default_constraints dc WHERE dc.parent_object_id = dim.object_id AND dc.parent_column_id = dimCol.column_id AND dc.definition LIKE ''%NEXT VALUE FOR%''));

        SELECT @FactBusinessFK = COUNT(DISTINCT fk.parent_object_id)
        FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk
        JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
        JOIN ' + QUOTENAME(@DbName) + N'.sys.tables dim ON fkc.referenced_object_id = dim.object_id
        JOIN ' + QUOTENAME(@DbName) + N'.sys.columns dimCol ON fkc.referenced_object_id = dimCol.object_id AND fkc.referenced_column_id = dimCol.column_id
        WHERE fk.parent_object_id IN (SELECT object_id FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE name LIKE ''fact[_]%''')
          AND dim.name LIKE ''dim[_]%''
          AND NOT (EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = dim.object_id AND ic.column_id = dimCol.column_id)
               OR EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.default_constraints dc WHERE dc.parent_object_id = dim.object_id AND dc.parent_column_id = dimCol.column_id AND dc.definition LIKE ''%NEXT VALUE FOR%''));

        IF @DimTotal = 0 AND @FactTotal = 0 SET @DbScore = 0;
        ELSE BEGIN
            IF @DimTotal > 0 AND @DimSurrogate = @DimTotal SET @DbScore = 2;
            IF @FactTotal > 0 AND @FactSurrogateFK = @FactTotal AND @FactBusinessFK = 0 SET @DbScore = 3;
            IF @DimSurrogate > 0 AND @FactBusinessFK > 0 SET @DbScore = 1;
            IF @DimSurrogate = 0 AND @DimTotal > 0 SET @DbScore = 0;
        END
        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);';
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