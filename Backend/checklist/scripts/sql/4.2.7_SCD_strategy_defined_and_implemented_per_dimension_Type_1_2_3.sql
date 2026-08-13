-- Checklist: SCD strategy defined and implemented per dimension (Type 1/2/3)
-- Scope: DATABASE
-- Scoring: 0=No dimension tables found, 1=Dims exist but lack SCD indicators, 2=Some dims have SCD indicator columns (proxy evidence), 3=All dims have explicit SCD type defined via extended properties
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
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DimCount INT = 0;
        DECLARE @ScdColCount INT = 0;
        DECLARE @ScdPropCount INT = 0;

        -- Identify dimension tables (schema = dim or name starts with dim_)
        SELECT @DimCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name = ''dim'' OR t.name LIKE ''dim_%'';

        IF @DimCount > 0
        BEGIN
            -- Check for SCD indicator columns (proxy evidence)
            SELECT @ScdColCount = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.columns c ON t.object_id = c.object_id
            WHERE (s.name = ''dim'' OR t.name LIKE ''dim_%'')
            AND c.name IN (''StartDate'', ''EndDate'', ''ValidFrom'', ''ValidTo'', ''CurrentFlag'', ''IsCurrent'', ''Version'', ''SCDType'');

            -- Check for explicit SCD type in extended properties (direct evidence)
            SELECT @ScdPropCount = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE (s.name = ''dim'' OR t.name LIKE ''dim_%'')
            AND ep.name IN (''SCDType'', ''SlowlyChangingDimension'', ''SCD Strategy'');
        END

        DECLARE @DbScore INT = 0;
        IF @DimCount = 0 SET @DbScore = 0;
        ELSE IF @ScdColCount = 0 AND @ScdPropCount = 0 SET @DbScore = 1;
        ELSE IF @ScdColCount + @ScdPropCount < @DimCount SET @DbScore = 2;
        ELSE IF @ScdPropCount = @DimCount SET @DbScore = 3;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;