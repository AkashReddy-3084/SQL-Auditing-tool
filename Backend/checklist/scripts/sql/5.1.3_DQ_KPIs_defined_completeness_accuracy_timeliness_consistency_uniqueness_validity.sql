-- Checklist: DQ KPIs defined: completeness, accuracy, timeliness, consistency, uniqueness, validity
-- Scope: DATABASE
-- Scoring: 0=No DQ references found; 1=1-2 dimensions referenced; 2=3-6 dimensions referenced (capped at 2 due to proxy evidence); Result=Pass if Score>=2
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
        DECLARE @DimsFound INT = 0;
        SELECT @DimsFound = COUNT(DISTINCT Dim)
        FROM (
            SELECT ''completeness'' AS Dim FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%completeness%'' OR t.name LIKE ''%completeness%''
            UNION ALL SELECT ''accuracy'' FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%accuracy%'' OR t.name LIKE ''%accuracy%''
            UNION ALL SELECT ''timeliness'' FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%timeliness%'' OR t.name LIKE ''%timeliness%''
            UNION ALL SELECT ''consistency'' FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%consistency%'' OR t.name LIKE ''%consistency%''
            UNION ALL SELECT ''uniqueness'' FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%uniqueness%'' OR t.name LIKE ''%uniqueness%''
            UNION ALL SELECT ''validity'' FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%validity%'' OR t.name LIKE ''%validity%''
            UNION ALL SELECT ''completeness'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%completeness%''
            UNION ALL SELECT ''accuracy'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%accuracy%''
            UNION ALL SELECT ''timeliness'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%timeliness%''
            UNION ALL SELECT ''consistency'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%consistency%''
            UNION ALL SELECT ''uniqueness'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%uniqueness%''
            UNION ALL SELECT ''validity'' FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%validity%''
        ) AS Dims;

        DECLARE @DbScore INT = CASE
            WHEN @DimsFound = 0 THEN 0
            WHEN @DimsFound <= 2 THEN 1
            ELSE 2
        END;
        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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