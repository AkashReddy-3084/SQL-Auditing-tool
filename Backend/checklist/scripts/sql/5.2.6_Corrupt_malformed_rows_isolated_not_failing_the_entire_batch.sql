-- Checklist: Corrupt/malformed rows isolated (not failing the entire batch)
-- Scope: DATABASE
-- Scoring: 0=No evidence of error isolation; 1=Partial (error tables OR TRY/CATCH found, but not both); 2=Good (both error tables and TRY/CATCH found); 3=Strong (error tables + TRY/CATCH + explicit error routing logic detected). NOTE: This script provides automated evidence. Full compliance requires human review.
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
        -- Escape single quotes in database name for safe dynamic SQL string literal
        DECLARE @EscapedDbName NVARCHAR(256) = REPLACE(@DbName, '''', '''''');
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DbName NVARCHAR(256) = N''' + @EscapedDbName + N''';
        DECLARE @HasErrorTables BIT = 0;
        DECLARE @HasTryCatch BIT = 0;
        DECLARE @HasErrorRouting BIT = 0;

        IF EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
                   WHERE LOWER(s.name + ''.'' + t.name) LIKE ''%error%'' OR LOWER(s.name + ''.'' + t.name) LIKE ''%reject%'' OR LOWER(s.name + ''.'' + t.name) LIKE ''%bad%'' OR LOWER(s.name + ''.'' + t.name) LIKE ''%quarantine%'')
            SET @HasErrorTables = 1;

        IF EXISTS (SELECT 1 FROM sys.procedures p JOIN sys.sql_modules m ON p.object_id = m.object_id
                   WHERE m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'' AND m.is_encrypted = 0)
            SET @HasTryCatch = 1;

        IF EXISTS (SELECT 1 FROM sys.procedures p JOIN sys.sql_modules m ON p.object_id = m.object_id
                   WHERE m.definition LIKE ''%INSERT%'' AND (m.definition LIKE ''%error%'' OR m.definition LIKE ''%reject%'') AND m.is_encrypted = 0)
            SET @HasErrorRouting = 1;

        DECLARE @DbScore INT = 0;
        IF @HasErrorTables = 1 AND @HasTryCatch = 1 AND @HasErrorRouting = 1 SET @DbScore = 3;
        ELSE IF @HasErrorTables = 1 AND @HasTryCatch = 1 SET @DbScore = 2;
        ELSE IF @HasErrorTables = 1 OR @HasTryCatch = 1 SET @DbScore = 1;

        SELECT @DbName, @DbScore;
        ';
        INSERT INTO #DbResults (DbName, DbScore)
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