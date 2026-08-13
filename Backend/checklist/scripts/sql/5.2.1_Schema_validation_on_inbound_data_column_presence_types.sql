-- Checklist: Schema validation on inbound data (column presence, types)
-- Scope: DATABASE
-- Scoring: 0=No staging/ETL artifacts; 1=Staging exists but loose types/no validation; 2=ETL contains type casts/conversions or strict staging types; 3=Not applicable (capped at 2 for proxy evidence)
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
        DECLARE @StagingCount INT = 0;
        DECLARE @ValidationCount INT = 0;
        DECLARE @CastCount INT = 0;
        DECLARE @StrictTypeCount INT = 0;

        -- Check for staging/landing tables
        SELECT @StagingCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name LIKE ''stg%'' OR s.name LIKE ''staging%'' OR s.name LIKE ''landing%'' OR s.name LIKE ''raw%'';

        -- Check for strict types in staging (not NVARCHAR/VARCHAR(MAX))
        SELECT @StrictTypeCount = COUNT(*) FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.types tp ON c.user_type_id = tp.user_type_id
        WHERE (s.name LIKE ''stg%'' OR s.name LIKE ''staging%'' OR s.name LIKE ''landing%'' OR s.name LIKE ''raw%'')
        AND (tp.name NOT IN (''nvarchar'', ''varchar'') OR c.max_length > 0);

        -- Check ETL procs for explicit validation/schema logic
        SELECT @ValidationCount = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%validate%'' OR m.definition LIKE ''%schema%'' OR m.definition LIKE ''%missing column%'';

        -- Check ETL procs for type enforcement via casting/conversion
        SELECT @CastCount = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE ''%cast(%'' OR m.definition LIKE ''%convert(%'';

        DECLARE @DbScore INT = 0;
        IF @StagingCount = 0 SET @DbScore = 0;
        ELSE IF @ValidationCount > 0 OR @CastCount > 0 SET @DbScore = 2;
        ELSE IF @StrictTypeCount > 0 SET @DbScore = 2;
        ELSE SET @DbScore = 1;

        -- Cap at 2 for proxy evidence
        IF @DbScore > 2 SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);
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