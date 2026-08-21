-- Checklist: ETL execution times monitored and baselined
-- Scope: SERVER
-- Scoring: 0: No monitoring artifacts or retention found. 1: Basic job history exists but lacks retention configuration. 2: Job history retention configured with historical duration data. 3: Explicit ETL logging/baseline tables detected with comprehensive tracking columns.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @JobHistoryCount INT = 0;
DECLARE @RetentionRows INT = 0;

-- NOTE: This script provides automated evidence. Full compliance requires human review.

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    -- Azure SQL DB lacks msdb and sys.configurations. Check current DB for custom logging tables.
    SELECT @JobHistoryCount = COUNT(*)
    FROM sys.tables t
    JOIN sys.columns c ON t.object_id = c.object_id
    WHERE (t.name LIKE '%ETL%' OR t.name LIKE '%LOG%' OR t.name LIKE '%RUN%')
      AND (c.name LIKE '%duration%' OR c.name LIKE '%start%' OR c.name LIKE '%end%' OR c.name LIKE '%time%');

    IF @JobHistoryCount > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Custom ETL logging tables detected in current database with duration/time columns. Baseline tracking likely implemented.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No ETL logging tables or monitoring artifacts found in Azure SQL Database. Execution time tracking not detected.';
    END
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    -- Check job history retention configuration
    SELECT @RetentionRows = ISNULL(CONVERT(INT, value_in_use), 0)
    FROM sys.configurations
    WHERE name = 'job history max rows';

    -- Check job history record count
    SELECT @JobHistoryCount = COUNT(*)
    FROM msdb.dbo.sysjobhistory;

    IF @JobHistoryCount > 0 AND @RetentionRows > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'SQL Agent job history retention configured (' + CAST(@RetentionRows AS NVARCHAR) + ' rows). ' + CAST(@JobHistoryCount AS NVARCHAR) + ' historical run records found with duration tracking.';
    END
    ELSE IF @JobHistoryCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Job history records exist (' + CAST(@JobHistoryCount AS NVARCHAR) + '), but retention configuration is missing or minimal.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No job history records or retention configuration found. ETL execution monitoring not detected.';
    END

    -- Check for explicit ETL logging/baseline tables in msdb
    IF EXISTS (
        SELECT 1
        FROM msdb.sys.tables t
        JOIN msdb.sys.columns c ON t.object_id = c.object_id
        WHERE (t.name LIKE '%ETL%' OR t.name LIKE '%LOG%')
          AND (c.name LIKE '%duration%' OR c.name LIKE '%start%' OR c.name LIKE '%end%')
    )
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Explicit ETL logging/baseline tables detected in msdb with duration tracking columns. Comprehensive monitoring configured.';
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;