-- Checklist: ETL is parameterized (no hardcoded servers, paths, dates, or credentials)
-- Scope: SERVER
-- Scoring: 3 = no hardcoded patterns found; 2 = 1-3 patterns found; 1 = 4-10 patterns found; 0 = >10 patterns found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No evidence found';

DECLARE @HardcodedCount INT = 0;

-- Temporary table to hold detected hardcoded strings
CREATE TABLE #Findings (ObjectName NVARCHAR(MAX), Evidence NVARCHAR(MAX));

-- 1. Check SQL Agent Job Steps for hardcoded patterns (Server level)
INSERT INTO #Findings (ObjectName, Evidence)
SELECT 
    'Job: ' + j.name + ' Step: ' + CAST(s.step_id AS NVARCHAR(10)),
    s.command
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON s.job_id = j.job_id
WHERE 
    s.command LIKE '%[0-9]%.[0-9]%.[0-9]%.[0-9]%'
    OR s.command LIKE '%C:\%'
    OR s.command LIKE '%D:\%'
    OR s.command LIKE '%Password=%'
    OR s.command LIKE '%User ID=%';

-- 2. Check stored procedures and functions across all user databases
DECLARE @DbName NVARCHAR(255);
DECLARE @DynamicSql NVARCHAR(MAX);

DECLARE db_cursor CURSOR FOR 
SELECT name FROM sys.databases 
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DynamicSql = N'
    INSERT INTO #Findings (ObjectName, Evidence)
    SELECT 
        ''' + @DbName + '''.'' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name),
        m.definition
    FROM ' + QUOTENAME(@DbName) + '.sys.sql_modules m
    JOIN ' + QUOTENAME(@DbName) + '.sys.objects o ON m.object_id = o.object_id
    WHERE 
        m.definition LIKE ''%[0-9]%.[0-9]%.[0-9]%.[0-9]%''
        OR m.definition LIKE ''%C:\%''
        OR m.definition LIKE ''%D:\%''
        OR m.definition LIKE ''%Password=%''
        OR m.definition LIKE ''%User ID=%''';

    EXEC sp_executesql @DynamicSql;
    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @HardcodedCount = COUNT(*) FROM #Findings;

IF @HardcodedCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No hardcoded servers, paths, or credentials detected in modules or jobs.';
END
ELSE
BEGIN
    -- Aggregate findings, limiting to first 5 to keep output concise
    SELECT @Finding = 'Hardcoded values found in ' + CAST(@HardcodedCount AS NVARCHAR(10)) + ' objects: ' + 
           STRING_AGG(CAST(ObjectName AS NVARCHAR(MAX)), ', ')
    FROM (SELECT TOP 5 ObjectName FROM #Findings) AS t;

    SET @Score = CASE 
        WHEN @HardcodedCount <= 3 THEN 2 
        WHEN @HardcodedCount <= 10 THEN 1 
        ELSE 0 
    END;
END

DROP TABLE #Findings;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;