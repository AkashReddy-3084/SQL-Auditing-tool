-- Checklist: Consistency checks (DBCC CHECKDB) scheduled and monitored (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 3=All user DBs have enabled jobs with valid schedules (weekly+) and successful runs within 14 days; 2=Jobs exist and are scheduled but runs are older or have warnings; 1=Jobs exist but lack schedules or recent history; 0=No jobs found or all disabled.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = 'master';
    SET @Finding = 'Azure SQL Database automatically performs consistency checks. Manual scheduling is not required.';
END
ELSE
BEGIN
    DECLARE @DbResults TABLE (DbName sysname, DbScore INT, Finding NVARCHAR(MAX));
    DECLARE @UserDbs TABLE (DbName sysname);

    INSERT INTO @UserDbs
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    IF NOT EXISTS (SELECT 1 FROM @UserDbs)
    BEGIN
        SET @Score = 3;
        SET @DatabaseQueried = 'master';
        SET @Finding = 'No user databases found. Check is not applicable.';
    END
    ELSE
    BEGIN
        CREATE TABLE #CheckJobs (
            JobName sysname,
            JobId uniqueidentifier,
            StepId INT,
            Command NVARCHAR(MAX),
            FreqType INT,
            FreqRecurrenceFactor INT
        );

        DECLARE @MsdbAccessible BIT = 1;
        BEGIN TRY
            INSERT INTO #CheckJobs
            SELECT j.name, j.job_id, js.step_id, js.command,
                   s.freq_type, s.freq_recurrence_factor
            FROM msdb.dbo.sysjobs j
            JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
            LEFT JOIN msdb.dbo.sysjobschedules jsch ON j.job_id = jsch.job_id
            LEFT JOIN msdb.dbo.sysschedules s ON jsch.schedule_id = s.schedule_id
            WHERE j.enabled = 1
              AND (js.command LIKE '%DBCC CHECKDB%' OR j.name LIKE '%DBCC CHECKDB%');
        END TRY
        BEGIN CATCH
            SET @MsdbAccessible = 0;
        END CATCH;

        IF @MsdbAccessible = 0
        BEGIN
            INSERT INTO @DbResults (DbName, DbScore, Finding)
            SELECT DbName, 0, 'msdb not accessible. Manual verification required.'
            FROM @UserDbs;
        END
        ELSE
        BEGIN
            DECLARE @DbName sysname;
            DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DbName FROM @UserDbs ORDER BY DbName;

            OPEN db_cursor;
            FETCH NEXT FROM db_cursor INTO @DbName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @HasJob BIT = 0;
                DECLARE @HasSchedule BIT = 0;
                DECLARE @LastRunDate DATETIME = NULL;
                DECLARE @LastRunStatus INT = NULL;
                DECLARE @JobId uniqueidentifier = NULL;
                DECLARE @StepId INT = NULL;
                DECLARE @DbScore INT = 0;
                DECLARE @DbFinding NVARCHAR(MAX) = '';

                SELECT TOP 1 @JobId = JobId, @StepId = StepId, @HasJob = 1,
                             @HasSchedule = CASE WHEN FreqType IN (4,8,16,32) AND FreqRecurrenceFactor > 0 THEN 1 ELSE 0 END
                FROM #CheckJobs
                WHERE JobName LIKE '%' + @DbName + '%'
                   OR Command LIKE '%' + QUOTENAME(@DbName) + '%'
                   OR Command LIKE '%[' + @DbName + ']%'
                   OR Command LIKE '%' + @DbName + '%';

                IF @HasJob = 1
                BEGIN
                    SELECT TOP 1 @LastRunDate = msdb.dbo.agent_datetime(run_date, run_time),
                               @LastRunStatus = run_status
                    FROM msdb.dbo.sysjobhistory
                    WHERE job_id = @JobId AND step_id = @StepId
                    ORDER BY run_date DESC, run_time DESC;

                    IF @LastRunStatus = 0 AND @LastRunDate >= DATEADD(day, -14, GETDATE()) AND @HasSchedule = 1
                        SET @DbScore = 3;
                    ELSE IF @HasSchedule = 1 AND @LastRunStatus = 0
                        SET @DbScore = 2;
                    ELSE IF @HasSchedule = 0 AND @LastRunStatus = 0
                        SET @DbScore = 1;
                    ELSE IF @HasSchedule = 1 AND @LastRunStatus IS NULL
                        SET @DbScore = 1;
                    ELSE
                        SET @DbScore = 0;

                    SET @DbFinding = 'Job: ' + (SELECT TOP 1 JobName FROM #CheckJobs WHERE JobId = @JobId) + 
                                     ', Schedule: ' + CASE WHEN @HasSchedule = 1 THEN 'Yes' ELSE 'No' END + 
                                     ', LastRun: ' + ISNULL(CONVERT(NVARCHAR, @LastRunDate, 120), 'Never') + 
                                     ', Status: ' + CASE @LastRunStatus WHEN 0 THEN 'Success' WHEN 1 THEN 'Succeeded with warnings' WHEN 2 THEN 'Failed' ELSE 'Unknown' END;
                END
                ELSE
                BEGIN
                    SET @DbScore = 0;
                    SET @DbFinding = 'No DBCC CHECKDB job found';
                END

                INSERT INTO @DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);

                FETCH NEXT FROM db_cursor INTO @DbName;
            END

            CLOSE db_cursor;
            DEALLOCATE db_cursor;
        END

        DROP TABLE #CheckJobs;

        SET @DatabaseQueried = 'master';
        SET @Score = ISNULL((SELECT MIN(DbScore) FROM @DbResults), 0);
        SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM @DbResults), 'No findings');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;