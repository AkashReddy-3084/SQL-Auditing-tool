-- Checklist: Boolean / Flag: only expected values; consistent representation across tables
-- Scope: DATABASE
-- Scoring: 0=No validation constraints; 1=Partial (<50% constrained); 2=Most (50-99% constrained); 3=Full (100% constrained). Capped at 2 as proxy evidence.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
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
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TotalCols INT = 0;
        DECLARE @ConstrainedCols INT = 0;

        SELECT @TotalCols = COUNT(*) FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        WHERE t.name = ''bit''
           OR c.name LIKE ''%is_%''
           OR c.name LIKE ''%flag%''
           OR c.name LIKE ''%active%''
           OR c.name LIKE ''%enabled%''
           OR c.name LIKE ''%deleted%''
           OR c.name LIKE ''%valid%'';

        SELECT @ConstrainedCols = COUNT(DISTINCT c.object_id) FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        LEFT JOIN sys.check_constraints cc ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
        LEFT JOIN sys.default_constraints dc ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
        WHERE (t.name = ''bit''
           OR c.name LIKE ''%is_%''
           OR c.name LIKE ''%flag%''
           OR c.name LIKE ''%active%''
           OR c.name LIKE ''%enabled%''
           OR c.name LIKE ''%deleted%''
           OR c.name LIKE ''%valid%'')
          AND (cc.object_id IS NOT NULL OR dc.object_id IS NOT NULL);

        DECLARE @DbScore INT = 0;
        IF @TotalCols = 0 SET @DbScore = 3;
        ELSE BEGIN
            DECLARE @Ratio FLOAT = CAST(@ConstrainedCols AS FLOAT) / NULLIF(@TotalCols, 0);
            IF @Ratio >= 0.9 SET @DbScore = 2;
            ELSE IF @Ratio >= 0.5 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END;

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

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.