-- Checklist: In-scope regulated data categories identified and inventoried
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal (1-5 tagged cols or 1 inventory table), 2=Good (6-20 tagged cols or populated inventory table), 3=Strong (>20 tagged cols or comprehensive inventory table). Capped at 2 due to proxy nature.
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
    DECLARE @DbScore INT = 0;
    DECLARE @TaggedCount INT = 0;
    DECLARE @InventoryTableCount INT = 0;

    BEGIN TRY
        -- Condition A: Check for extended properties tagging regulated data
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @TaggedCount = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
        JOIN sys.tables t ON c.object_id = t.object_id
        WHERE ep.name LIKE ''%DataClassification%'' OR ep.name LIKE ''%PII%'' OR ep.name LIKE ''%Regulated%'' OR ep.name LIKE ''%PHI%'' OR ep.name LIKE ''%Sensitive%'';';
        EXEC sp_executesql @Sql, N'@TaggedCount INT OUTPUT', @TaggedCount OUTPUT;

        -- Condition B: Check for inventory/catalog tables
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @InventoryTableCount = COUNT(*)
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''%Inventory%'' OR t.name LIKE ''%Catalog%'' OR t.name LIKE ''%Classification%'' OR t.name LIKE ''%DataMap%'' OR t.name LIKE ''%DataDictionary%'';';
        EXEC sp_executesql @Sql, N'@InventoryTableCount INT OUTPUT', @InventoryTableCount OUTPUT;

        -- Calculate ScoreA independently
        DECLARE @ScoreA INT = 0;
        IF @TaggedCount > 0
        BEGIN
            IF @TaggedCount <= 5 SET @ScoreA = 1;
            ELSE IF @TaggedCount <= 20 SET @ScoreA = 2;
            ELSE SET @ScoreA = 3;
        END

        -- Calculate ScoreB independently
        DECLARE @ScoreB INT = 0;
        IF @InventoryTableCount > 0 SET @ScoreB = 2;

        -- Combine using MAX to enforce OR precedence without overwriting
        SET @DbScore = CASE WHEN @ScoreA > @ScoreB THEN @ScoreA ELSE @ScoreB END;

    END TRY
    BEGIN CATCH
        SET @DbScore = 0;
    END CATCH;

    INSERT INTO #DbResults VALUES (@DbName, @DbScore);
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

-- NOTE: This script provides automated evidence. Full compliance requires human review.
-- Cap at 2 for proxy/indirect evidence as per scoring guidelines
SET @Score = CASE WHEN @Score > 2 THEN 2 ELSE @Score END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;