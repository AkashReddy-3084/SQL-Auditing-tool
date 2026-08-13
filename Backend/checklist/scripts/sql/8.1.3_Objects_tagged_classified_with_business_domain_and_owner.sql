-- Checklist: Objects tagged/classified with business domain and owner
-- Scope: DATABASE
-- Scoring: 0=No tags found, 1=1-19% coverage, 2=20-79% coverage, 3=>=80% coverage
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
        DECLARE @TotalObjects INT;
        DECLARE @TaggedObjects INT;
        DECLARE @Pct FLOAT;
        DECLARE @DbScore INT;

        SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'');

        SELECT @TaggedObjects = COUNT(DISTINCT o.object_id)
        FROM sys.objects o
        JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0 AND ep.class = 1
        WHERE o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
        AND (ep.name LIKE ''%domain%'' OR ep.name LIKE ''%owner%'' OR ep.name LIKE ''%business%'' OR ep.name LIKE ''%classification%'' OR ep.name LIKE ''%tag%'');

        SET @Pct = CASE WHEN @TotalObjects = 0 THEN 100.0 ELSE (@TaggedObjects * 100.0) / @TotalObjects END;

        SET @DbScore = CASE 
            WHEN @Pct >= 80.0 THEN 3
            WHEN @Pct >= 20.0 THEN 2
            WHEN @Pct > 0.0 THEN 1
            ELSE 0
        END;

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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