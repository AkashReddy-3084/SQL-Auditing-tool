DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobHistoryCount INT = 0;
DECLARE @LogTableCount INT = 0;
DECLARE @BaselineArtifactCount INT = 0;

-- Check SQL Agent job history for recent successful runs with duration
IF OBJECT_ID('msdb.dbo.sysjobhistory') IS NOT NULL
BEGIN
    SELECT @JobHistoryCount = COUNT(*)
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
    WHERE h.run_status = 1 
      AND h.run_duration > 0 
      AND h.step_id = 0 
      AND h.run_date >= CONVERT(INT, CONVERT(VARCHAR(8), DATEADD(DAY, -7, GETDATE()), 112));
END

-- Check for custom ETL logging tables and baseline artifacts across all online user databases
DECLARE @DBName NVARCHAR(128);
DECLARE @SQL NVARCHAR(MAX);

DECLARE db_cursor CURSOR FOR
SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Check for ETL logging tables
    SET @SQL = N'SELECT @LogTableCount = COUNT(*) FROM [' + @DBName + N'].sys.tables t JOIN [' + @DBName + N'].sys.schemas s ON t.schema_id = s.schema_id WHERE s.name + ''.'' + t.name LIKE ''%etl%log%'' OR s.name + ''.'' + t.name LIKE ''%job%log%'' OR s.name + ''.'' + t.name LIKE ''%perf%log%'';';
    EXEC sp_executesql @SQL, N'@LogTableCount INT OUTPUT', @LogTableCount OUTPUT;

    -- Check for baseline calculation artifacts (tables or procs)
    SET @SQL = N'SELECT @BaselineArtifactCount = COUNT(*) FROM (SELECT name FROM [' + @DBName + N'].sys.tables WHERE name LIKE ''%baseline%'' OR name LIKE ''%threshold%'' UNION ALL SELECT name FROM [' + @DBName + N'].sys.procedures WHERE name LIKE ''%baseline%'' OR name LIKE ''%etl%monitor%'' OR name LIKE ''%perf%calc%'') AS BaselineArtifacts;';
    EXEC sp_executesql @SQL, N'@BaselineArtifactCount INT OUTPUT', @BaselineArtifactCount OUTPUT;

    FETCH NEXT FROM db_cursor INTO @DBName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Determine score based on highest-level artifact found
IF @BaselineArtifactCount > 0 SET @Score = 3;
ELSE IF @LogTableCount > 0 SET @Score = 2;
ELSE IF @JobHistoryCount > 0 SET @Score = 1;
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;