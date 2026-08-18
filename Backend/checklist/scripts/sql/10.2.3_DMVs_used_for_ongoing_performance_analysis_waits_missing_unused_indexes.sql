-- Checklist: DMVs used for ongoing performance analysis (waits, missing/unused indexes)
-- Scope: SERVER
-- Scoring: 3=Query Store enabled for all user DBs or jobs monitor both waits/indexes; 2=Partial Query Store or jobs monitor only one category; 1=DMVs accessible but no automated monitoring configured; 0=DMVs inaccessible or completely non-compliant.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @WaitJobs INT = 0;
DECLARE @IndexJobs INT = 0;
DECLARE @QSEnabledCount INT = 0;
DECLARE @TotalUserDBs INT = 0;
DECLARE @QsDbNames NVARCHAR(MAX) = '';

-- Check Query Store status for user databases
SELECT @QSEnabledCount = COUNT(*), @TotalUserDBs = COUNT(*)
FROM sys.databases d
JOIN sys.database_query_store_options q ON d.database_id = q.database_id
WHERE d.database_id > 4 AND d.state = 0 AND q.actual_state = 1;

SELECT @QsDbNames = STRING_AGG(name, ', ')
FROM sys.databases d
JOIN sys.database_query_store_options q ON d.database_id = q.database_id
WHERE d.database_id > 4 AND d.state = 0 AND q.actual_state = 1;

-- Check SQL Agent jobs for DMV references (SQL Server / MI only)
IF @EngineEdition <> 5
BEGIN
    SELECT @WaitJobs = COUNT(*)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1 AND CAST(js.command AS NVARCHAR(MAX)) LIKE '%sys.dm_os_wait_stats%';

    SELECT @IndexJobs = COUNT(*)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1 AND (CAST(js.command AS NVARCHAR(MAX)) LIKE '%sys.dm_db_missing_index_details%' 
                            OR CAST(js.command AS NVARCHAR(MAX)) LIKE '%sys.dm_db_index_usage_stats%');
END

-- Determine Score
IF @TotalUserDBs = 0
    SET @Score = 3;
ELSE IF @QSEnabledCount = @TotalUserDBs
    SET @Score = 3;
ELSE IF @QSEnabledCount > 0 OR @WaitJobs > 0 OR @IndexJobs > 0
    SET @Score = 2;
ELSE
    SET @Score = 1;

-- Construct Finding
SET @Finding = 'Total user databases: ' + CAST(@TotalUserDBs AS NVARCHAR(10)) + '; ';
SET @Finding = @Finding + 'Query Store enabled: ' + CAST(@QSEnabledCount AS NVARCHAR(10)) + ' (' + ISNULL(@QsDbNames, 'None') + '); ';
IF @EngineEdition <> 5
    SET @Finding = @Finding + 'Wait monitoring jobs: ' + CAST(@WaitJobs AS NVARCHAR(10)) + '; Index monitoring jobs: ' + CAST(@IndexJobs AS NVARCHAR(10)) + '; ';
ELSE
    SET @Finding = @Finding + 'Platform: Azure SQL Database (SQL Agent jobs not applicable); ';

IF @Score = 3
    SET @Finding = @Finding + 'Fully compliant: Comprehensive performance monitoring configured.';
ELSE IF @Score = 2
    SET @Finding = @Finding + 'Partially compliant: Monitoring covers some databases or only one performance category.';
ELSE IF @Score = 1
    SET @Finding = @Finding + 'DMVs are accessible but no automated monitoring or Query Store is configured.';
ELSE
    SET @Finding = @Finding + 'Non-compliant: DMVs are inaccessible or completely unmonitored.';

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;