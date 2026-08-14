```sql
-- Checklist: DQ SLAs defined per data product / mart
-- Scope: DATABASE
-- Scoring: 
--   0 = Fail: No evidence of SLA definitions (no metadata, no config tables).
--   1 = Partial Pass: Generic descriptions found, but no specific SLA/DQ keywords.
--   2 = Mostly Pass: Specific SLA/DQ metadata found on some objects (< 50% coverage).
--   3 = Pass: Specific SLA/DQ metadata found on most objects (> 50% coverage) OR dedicated DQ config table exists.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;
DECLARE @TotalObjects INT;
DECLARE @SlaObjects INT;
DECLARE @ConfigTableExists INT;

-- Create temp table to collect per-database results
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Initialize counters
        SET @TotalObjects = 0;
        SET @SlaObjects = 0;
        SET @ConfigTableExists = 0;

        -- 1. Check for dedicated DQ/SLA configuration tables (e.g., DQ_SLA, Config_SLA)
        -- 2. Count total user tables/views
        -- 3. Count objects with SLA-related extended properties
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @ConfigTableExists = COUNT(*) 
        FROM sys.tables 
        WHERE name LIKE ''%SLA%'' OR name LIKE ''%DQ%'' OR name LIKE ''%ServiceLevel%'';
        
        SELECT @TotalObjects = COUNT(*) 
        FROM sys.objects 
        WHERE type IN (''U'', ''V'') AND is_ms_shipped = 0;

        SELECT @SlaObjects = COUNT(DISTINCT major_id)
        FROM sys.extended_properties
        WHERE class = 1 -- Object or column
          AND (name LIKE ''%SLA%'' OR name LIKE ''%DQ%'' OR name LIKE ''%ServiceLevel%'' OR name LIKE ''%Refresh%'')
          AND major_id IN (SELECT object_id FROM sys.objects WHERE type IN (''U'', ''V'') AND is_ms_shipped = 0);
        ';
        
        -- FIXED: Removed OUTPUT from parameter declaration string. OUTPUT is only used in the value list.
        EXEC sp_executesql @Sql, 
            N'@ConfigTableExists INT, @TotalObjects INT, @SlaObjects INT',
            @ConfigTableExists OUTPUT, @TotalObjects OUTPUT, @SlaObjects OUTPUT;

        -- Determine DB Score
        IF @ConfigTableExists > 0
            SET @DbScore = 3;
        ELSE IF @TotalObjects > 0 AND @SlaObjects > 0
        BEGIN
            -- Calculate coverage percentage
            DECLARE @Coverage FLOAT = CAST(@SlaObjects AS FLOAT) / CAST(@TotalObjects AS FLOAT);
            IF @Coverage > 0.5
                SET @DbScore = 3;
            ELSE
                SET @DbScore = 2;
        END
        ELSE
        BEGIN
            -- Check for generic descriptions as weak evidence
            -- FIXED: Added filter to user objects only for consistency
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @SlaObjects = COUNT(*) 
            FROM sys.extended_properties 
            WHERE name = ''MS_Description'' 
              AND class = 1
              AND major_id IN (SELECT object_id FROM sys.objects WHERE type IN (''U'', ''V'') AND is_ms_shipped = 0);';
            EXEC sp_executesql @Sql, N'@SlaObjects INT', @SlaObjects OUTPUT;
            
            IF @SlaObjects > 0
                SET @DbScore = 1;
            ELSE
                SET @DbScore = 0;
        END

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);

    END TRY
    BEGIN CATCH
        -- If we can't query the DB, it's a fail for that DB
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
```