-- Checklist: Fragmentation-based maintenance (rebuild/reorganize) automated
-- Scope: SERVER
-- Scoring: 0=No automation found; 1=Jobs exist but disabled/unscheduled or moderate fragmentation; 2=Enabled scheduled jobs found or low fragmentation; 3=Fully automated with rebuild/reorganize logic and active schedules
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @EnabledJobCount INT = 0;
DECLARE @ScheduledJobCount INT = 0;
DECLARE @AvgFrag FLOAT = 100.0;

-- Check for SQL Agent jobs (On-Prem / MI)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    -- Count ALL jobs (enabled or disabled) containing index maintenance commands
    SELECT @JobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE (js.command LIKE '%ALTER INDEX%' OR js.command LIKE '%REBUILD%' OR js.command LIKE '%REORGANIZE%' OR js.command LIKE '%sp_indexoption%' OR js.command LIKE '%IndexOptimize%');

    -- Count only ENABLED jobs containing index maintenance commands
    SELECT @EnabledJobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1
      AND (js.command LIKE '%ALTER INDEX%' OR js.command LIKE '%REBUILD%' OR js.command LIKE '%REORGANIZE%' OR js.command LIKE '%sp_indexoption%' OR js.command LIKE '%IndexOptimize%');

    -- Count ENABLED jobs with active schedules containing index maintenance commands
    SELECT @ScheduledJobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    INNER JOIN msdb.dbo.sysjobschedules jsch ON j.job_id = jsch.job_id
    WHERE j.enabled = 1
      AND (js.command LIKE '%ALTER INDEX%' OR js.command LIKE '%REBUILD%' OR js.command LIKE '%REORGANIZE%' OR js.command LIKE '%sp_indexoption%' OR js.command LIKE '%IndexOptimize%');
END

-- Fallback: Check fragmentation levels across user databases (Azure SQL / No Jobs)
IF @JobCount = 0
BEGIN
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);
    CREATE TABLE #FragStats (DbName NVARCHAR(256), AvgFrag FLOAT);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            INSERT INTO #FragStats
            SELECT ''' + @DbName + ''', AVG(avg_fragmentation_in_percent)
            FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'')
            WHERE index_id > 0;';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #FragStats VALUES (@DbName, 100.0);
        END CATCH;
        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Use ISNULL to handle cases where no user databases exist
    SELECT @AvgFrag = ISNULL(AVG(AvgFrag), 100.0) FROM #FragStats;
    DROP TABLE #FragStats;
END

-- Determine Score
IF @ScheduledJobCount > 0
    SET @Score = 3;
ELSE IF @EnabledJobCount > 0
    SET @Score = 2;
ELSE IF @JobCount > 0
    SET @Score = 1;
ELSE
BEGIN
    -- Fallback to fragmentation levels
    IF @AvgFrag < 10.0 SET @Score = 3;
    ELSE IF @AvgFrag < 20.0 SET @Score = 2;
    ELSE IF @AvgFrag < 30.0 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;