-- Checklist: Fact table grain clearly defined and documented per fact
-- Scope: DATABASE
-- Scoring: 0=No fact tables or none documented; 1=1-49% documented; 2=50-99% documented; 3=100% documented via extended properties.
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
DECLARE @Total INT = 0;
DECLARE @Documented INT = 0;

SELECT @Total = COUNT(*)
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name LIKE ''fact%'' OR t.name LIKE ''fact%'' OR t.name LIKE ''fact_%'';

SELECT @Documented = COUNT(DISTINCT t.object_id)
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.extended_properties ep ON ep.major_id = t.object_id AND ep.minor_id = 0
WHERE (s.name LIKE ''fact%'' OR t.name LIKE ''fact%'' OR t.name LIKE ''fact_%'')
  AND (ep.name = ''Grain'' OR TRY_CAST(ep.value AS NVARCHAR(4000)) LIKE ''%grain%'');

INSERT INTO #DbResults
SELECT ''' + @DbName + ''',
       CASE
           WHEN @Total = 0 THEN 0
           WHEN @Documented = @Total THEN 3
           WHEN CAST(@Documented AS FLOAT) / @Total >= 0.5 THEN 2
           WHEN @Documented > 0 THEN 1
           ELSE 0
       END;';
        EXEC(@Sql);
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