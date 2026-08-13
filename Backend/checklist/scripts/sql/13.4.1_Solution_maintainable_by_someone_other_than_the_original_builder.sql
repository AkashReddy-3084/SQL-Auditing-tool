-- Checklist: Solution maintainable by someone other than the original builder
-- Scope: DATABASE
-- Scoring: 0=No documentation/schema separation, 1=Minimal docs or slight separation, 2=Good coverage & logical schemas, 3=Comprehensive docs, comments, & clear architecture
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

SET NOCOUNT ON;
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
        DECLARE @TotalObjects INT, @DocObjects INT, @CommentObjects INT, @SchemaCount INT;
        DECLARE @DocPct FLOAT, @CommentPct FLOAT, @MaintScore INT;

        SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;
        SELECT @DocObjects = COUNT(DISTINCT object_id) FROM sys.extended_properties WHERE class = 1 AND name = ''MS_Description'';
        SELECT @CommentObjects = COUNT(*) FROM sys.sql_modules WHERE definition LIKE ''%--%'' AND is_encrypted = 0 AND object_id IN (SELECT object_id FROM sys.objects WHERE type IN (''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0);
        SELECT @SchemaCount = COUNT(DISTINCT schema_id) FROM sys.objects WHERE type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;

        SET @DocPct = CASE WHEN @TotalObjects > 0 THEN CAST(@DocObjects AS FLOAT) / @TotalObjects ELSE 0 END;
        SET @CommentPct = CASE WHEN @TotalObjects > 0 THEN CAST(@CommentObjects AS FLOAT) / @TotalObjects ELSE 0 END;
        SET @MaintScore = 0;

        IF @DocPct >= 0.50 AND @CommentPct >= 0.30 AND @SchemaCount > 1 SET @MaintScore = 3;
        ELSE IF @DocPct >= 0.20 AND @CommentPct >= 0.10 AND @SchemaCount > 1 SET @MaintScore = 2;
        ELSE IF @DocPct >= 0.05 OR @SchemaCount > 1 SET @MaintScore = 1;
        ELSE SET @MaintScore = 0;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @MaintScore);';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.