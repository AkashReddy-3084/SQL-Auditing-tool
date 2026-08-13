-- Checklist: Scalar UDFs avoided in hot paths (inlined/replaced where they hurt performance)
-- Scope: DATABASE
-- Scoring: 0=Fail (Scalar UDFs exist & referenced, inlining OFF), 1=Partial (UDFs exist but unreferenced OR inlining ON), 2=Mostly Pass (No UDF references, inlining ON), 3=Pass (Zero scalar UDFs)
-- NOTE: This script provides automated evidence. Full compliance requires human review of "hot path" classification.
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
        DECLARE @UdfCount INT = 0;
        DECLARE @ReferencedCount INT = 0;
        DECLARE @InliningEnabled BIT = 0;

        SELECT @UdfCount = COUNT(*) FROM sys.objects WHERE type = ''FN'';

        SELECT @ReferencedCount = COUNT(DISTINCT sed.referenced_id)
        FROM sys.sql_expression_dependencies sed
        INNER JOIN sys.objects ref ON sed.referenced_id = ref.object_id
        WHERE ref.type = ''FN''
          AND sed.referencing_id IN (SELECT object_id FROM sys.objects WHERE type IN (''P'', ''V'', ''TR''));

        SELECT @InliningEnabled = ISNULL(DATABASEPROPERTYEX(DB_NAME(), ''IsScalarUDFInliningEnabled''), 0);

        DECLARE @DbScore INT = 0;
        IF @UdfCount = 0 SET @DbScore = 3;
        ELSE IF @ReferencedCount = 0 AND @InliningEnabled = 1 SET @DbScore = 2;
        ELSE IF @ReferencedCount = 0 OR @InliningEnabled = 1 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;