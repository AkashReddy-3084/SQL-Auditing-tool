-- Checklist: Watermark/control values persisted reliably (control table, not volatile)
-- Scope: DATABASE
-- Scoring: 0 = No control/watermark tables found; 1 = Tables found but lack typical watermark columns or procedure references; 2 = Persistent control tables with appropriate columns found; 3 = Control tables found, referenced by ETL procedures, and explicitly user-defined.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE state = 0 AND name NOT IN ('master', 'model', 'msdb', 'tempdb');

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @TableCount INT = 0;
DECLARE @ColCount INT = 0;
DECLARE @ProcRefCount INT = 0;

SELECT @TableCount = COUNT(*) FROM sys.tables t
WHERE OBJECTPROPERTY(t.object_id, ''IsMSShipped'') = 0
AND (t.name LIKE ''%control%'' OR t.name LIKE ''%watermark%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%batch%'');

IF @TableCount > 0
BEGIN
    SELECT @ColCount = COUNT(*) FROM sys.columns c
    JOIN sys.tables t ON c.object_id = t.object_id
    WHERE OBJECTPROPERTY(t.object_id, ''IsMSShipped'') = 0
    AND (t.name LIKE ''%control%'' OR t.name LIKE ''%watermark%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%batch%'')
    AND (c.name LIKE ''%watermark%'' OR c.name LIKE ''%load_date%'' OR c.name LIKE ''%max_id%'' OR c.name LIKE ''%run_date%'' OR c.name LIKE ''%batch%'');

    SELECT @ProcRefCount = COUNT(*) FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE OBJECTPROPERTY(p.object_id, ''IsMSShipped'') = 0
    AND (m.definition LIKE ''%control%'' OR m.definition LIKE ''%watermark%'' OR m.definition LIKE ''%load%'');
END

DECLARE @DbScore INT = 0;
IF @TableCount = 0 SET @DbScore = 0;
ELSE IF @ColCount = 0 AND @ProcRefCount = 0 SET @DbScore = 1;
ELSE IF @ColCount > 0 AND @ProcRefCount = 0 SET @DbScore = 2;
ELSE IF @ColCount > 0 AND @ProcRefCount > 0 SET @DbScore = 3;

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