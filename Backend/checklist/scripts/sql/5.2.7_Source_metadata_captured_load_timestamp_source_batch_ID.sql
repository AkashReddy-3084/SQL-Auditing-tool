-- Checklist: Source metadata captured (load timestamp, source, batch ID)
-- Scope: DATABASE
-- Scoring: 0=No metadata columns found; 1=1-24% tables have all 3; 2=25-74% tables have all 3; 3=>=75% tables have all 3.
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
        DECLARE @Total INT = (SELECT COUNT(*) FROM sys.tables WHERE type = ''U'');
        DECLARE @Match INT = (SELECT COUNT(*) FROM sys.tables t
            WHERE type = ''U''
              AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN (''load_date'',''load_timestamp'',''etl_load_date'',''ingestion_date''))
              AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN (''source_system'',''source'',''source_db'',''origin''))
              AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN (''batch_id'',''batch'',''load_batch'',''run_id'')));
        DECLARE @Pct FLOAT = CASE WHEN @Total > 0 THEN (@Match * 100.0 / @Total) ELSE 0 END;
        DECLARE @S INT = 0;
        IF @Pct >= 75 SET @S = 3;
        ELSE IF @Pct >= 25 SET @S = 2;
        ELSE IF @Pct > 0 SET @S = 1;
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @S);';
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