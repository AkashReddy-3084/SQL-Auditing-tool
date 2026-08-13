-- Checklist: Late-arriving / out-of-order data handled without corruption
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal (staging/load timestamps only), 2=Good (SCD patterns or MERGE/upsert logic found), 3=Strong (SCD + MERGE/upsert + partitioning/constraints found)
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
        DECLARE @DbScore INT = 0;
        DECLARE @StagingCount INT = 0;
        DECLARE @ScdCount INT = 0;
        DECLARE @MergeCount INT = 0;
        DECLARE @PartitionCount INT = 0;
        DECLARE @ConstraintCount INT = 0;

        -- Check for staging/landing tables with load timestamps
        SELECT @StagingCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE (s.name LIKE ''%stag%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'')
        AND EXISTS (
            SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id
            AND (c.name LIKE ''%load_date%'' OR c.name LIKE ''%batch_id%'' OR c.name LIKE ''%etl_timestamp%'')
        );

        -- Check for SCD Type 2 patterns (date ranges + current flag)
        SELECT @ScdCount = COUNT(*) FROM sys.tables t
        WHERE EXISTS (
            SELECT 1 FROM sys.columns c1 JOIN sys.columns c2 ON c1.object_id = c2.object_id
            WHERE c1.object_id = t.object_id
            AND (c1.name LIKE ''%start_date%'' OR c1.name LIKE ''%valid_from%'' OR c1.name LIKE ''%effective_start%'')
            AND (c2.name LIKE ''%end_date%'' OR c2.name LIKE ''%valid_to%'' OR c2.name LIKE ''%effective_end%'')
        )
        AND EXISTS (
            SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id
            AND (c.name LIKE ''%current%'' OR c.name LIKE ''%is_active%'')
        );

        -- Check for MERGE or upsert logic in procedures
        SELECT @MergeCount = COUNT(*) FROM sys.procedures p
        WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%MERGE%''
           OR (OBJECT_DEFINITION(p.object_id) LIKE ''%INSERT INTO%'' AND OBJECT_DEFINITION(p.object_id) LIKE ''%WHERE NOT EXISTS%'')
           OR (OBJECT_DEFINITION(p.object_id) LIKE ''%UPDATE%'' AND OBJECT_DEFINITION(p.object_id) LIKE ''%WHERE EXISTS%'');

        -- Check for partitioning on date columns
        SELECT @PartitionCount = COUNT(DISTINCT pf.name) FROM sys.partition_functions pf
        JOIN sys.partition_parameters pp ON pf.function_id = pp.function_id
        WHERE pp.parameter_id = 1 AND pp.user_type_id IN (
            SELECT user_type_id FROM sys.types WHERE name IN (''date'', ''datetime'', ''datetime2'', ''smalldatetime'')
        );

        -- Check for relevant constraints/triggers
        SELECT @ConstraintCount = COUNT(*) FROM sys.check_constraints cc
        WHERE OBJECT_DEFINITION(cc.object_id) LIKE ''%date%'' OR OBJECT_DEFINITION(cc.object_id) LIKE ''%order%'';

        -- Calculate DB score based on evidence strength
        SET @DbScore = 0;
        IF @StagingCount > 0 SET @DbScore = 1;
        IF @ScdCount > 0 OR @MergeCount > 0 SET @DbScore = 2;
        IF @ScdCount > 0 AND @MergeCount > 0 AND (@PartitionCount > 0 OR @ConstraintCount > 0) SET @DbScore = 3;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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