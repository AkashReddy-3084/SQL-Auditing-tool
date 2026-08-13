-- Checklist: All schema/code changes go through formal change management
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=Audit off but >=80% objects have change-tracking properties; 2=Audit on OR 40-79% coverage; 3=Audit on AND >=80% coverage
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName sysname;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName sysname, DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @AuditEnabled INT = 0;
        DECLARE @TotalObjects INT = 0;
        DECLARE @TrackedObjects INT = 0;
        DECLARE @DbScore INT = 0;

        IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE is_state_enabled = 1)
            SET @AuditEnabled = 1;

        SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''P'', ''V'', ''FN'', ''IF'', ''TF'');

        SELECT @TrackedObjects = COUNT(DISTINCT o.object_id) FROM sys.extended_properties ep
        INNER JOIN sys.objects o ON ep.major_id = o.object_id
        WHERE ep.class = 1 AND ep.minor_id = 0
          AND (ep.name LIKE ''%change%'' OR ep.name LIKE ''%ticket%'' OR ep.name LIKE ''%cm%'' OR ep.name LIKE ''%approval%'');

        DECLARE @Pct FLOAT = CASE WHEN @TotalObjects > 0 THEN (@TrackedObjects * 100.0 / @TotalObjects) ELSE 0 END;

        IF @AuditEnabled = 1 AND @Pct >= 80 SET @DbScore = 3;
        ELSE IF @AuditEnabled = 1 SET @DbScore = 2;
        ELSE IF @Pct >= 80 SET @DbScore = 1;
        ELSE IF @Pct >= 40 SET @DbScore = 2;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbNameParam sysname', @DbNameParam = @DbName;
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