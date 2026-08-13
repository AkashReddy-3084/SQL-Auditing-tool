-- Checklist: Date/Time dimension exists with required attributes
-- Scope: DATABASE
-- Scoring: 0 = No candidate table found; 1 = Table found with 1-2 expected attributes; 2 = Table found with 3-5 expected attributes; 3 = Table found with >=6 expected attributes (fully compliant).
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
        DECLARE @TableCount INT = 0;
        DECLARE @AttrCount INT = 0;
        
        SELECT @TableCount = COUNT(*) 
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.name LIKE ''%Date%'' OR t.name LIKE ''%Calendar%'' OR t.name LIKE ''%Time%'';
        
        IF @TableCount > 0
        BEGIN
            SELECT @AttrCount = ISNULL(MAX(AttrCount), 0)
            FROM (
                SELECT t.object_id, COUNT(c.name) AS AttrCount
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                JOIN sys.columns c ON t.object_id = c.object_id
                WHERE (t.name LIKE ''%Date%'' OR t.name LIKE ''%Calendar%'' OR t.name LIKE ''%Time%'')
                AND c.name IN (''DateKey'', ''FullDate'', ''CalendarYear'', ''CalendarQuarter'', ''CalendarMonth'', ''CalendarDay'', ''DayOfWeek'', ''IsHoliday'', ''WeekOfYear'', ''MonthName'', ''QuarterName'', ''YearQuarter'', ''MonthDay'')
                GROUP BY t.object_id
            ) AS Counts;
        END
        
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', CASE 
            WHEN @TableCount = 0 THEN 0
            WHEN @AttrCount = 0 THEN 0
            WHEN @AttrCount BETWEEN 1 AND 2 THEN 1
            WHEN @AttrCount BETWEEN 3 AND 5 THEN 2
            ELSE 3 
        END);
        ';
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