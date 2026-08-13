-- Checklist: Business glossary / terminology maintained
-- Scope: DATABASE
-- Scoring: 0 = 0% tables have glossary/description properties; 1 = 1-30%; 2 = 31-70%; 3 = >70%
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Cov INT = 0;
DECLARE @TotalTables INT = 0;
DECLARE @Pct FLOAT = 0.0;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Cov = 0;
        SET @TotalTables = 0;
        
        -- Get total tables in the database
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; SELECT @TotalTables = COUNT(*) FROM sys.tables;';
        EXEC sp_executesql @Sql, N'@TotalTables INT OUTPUT', @TotalTables OUTPUT;

        -- Get tables with glossary/description extended properties (table-level only)
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @Cov = COUNT(DISTINCT ep.major_id) FROM sys.extended_properties ep
        JOIN sys.tables t ON ep.major_id = t.object_id
        WHERE ep.class = 1 AND ep.minor_id = 0
        AND ep.name IN (''MS_Description'', ''BusinessTerm'', ''Glossary'', ''Description'');';
        EXEC sp_executesql @Sql, N'@Cov INT OUTPUT', @Cov OUTPUT;

        -- Calculate coverage percentage safely using float arithmetic
        IF @TotalTables > 0
            SET @Pct = (@Cov * 100.0) / CAST(@TotalTables AS FLOAT);
        ELSE
            SET @Pct = 100.0; -- Vacuously compliant for empty databases

        -- Determine per-database score
        IF @Pct > 70.0
            SET @Score = 3;
        ELSE IF @Pct > 30.0
            SET @Score = 2;
        ELSE IF @Pct > 0.0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        INSERT INTO #DbResults VALUES (@DbName, @Score);
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