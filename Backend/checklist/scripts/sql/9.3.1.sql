-- Checklist: Consistency checks (DBCC CHECKDB) scheduled and monitored (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 3 = Job exists and ran successfully in last 7 days; 2 = Job exists but failed/not run recently; 1 = Job exists but no history; 0 = No DBCC CHECKDB job found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No DBCC CHECKDB job found';

-- Azure SQL Database does not have SQL Agent/DBCC CHECKDB scheduling in the same way
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: Consistency checks are managed by the platform';
END
ELSE
BEGIN
    DECLARE @JobId BINARY(16);
    DECLARE @LastRunDate INT;
    DECLARE @LastRunTime INT;
    DECLARE @LastRunStatus INT;

    -- Identify a job that runs DBCC CHECKDB
    SELECT TOP 1 @JobId = j.job_id
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
    WHERE s.command LIKE '%DBCC%CHECKDB%' 
       OR s.command LIKE '%DBCC CHECKDB%';

    IF @JobId IS NOT NULL
    BEGIN
        -- Get the most recent execution status
        SELECT TOP 1 
            @LastRunDate = run_date, 
            @LastRunTime = run_time, 
            @LastRunStatus = run_status
        FROM msdb.dbo.sysjobhistory
        WHERE job_id = @JobId 
          AND step_id = 0 -- Job Outcome step
        ORDER BY run_date DESC, run_time DESC;

        IF @LastRunStatus = 1 -- Success
        BEGIN
            -- Convert YYYYMMDD integer to DATE for accurate comparison
            DECLARE @RunDateDate DATE = CAST(CAST(@LastRunDate AS VARCHAR(8)) AS DATE);
            
            IF DATEDIFF(DAY, @RunDateDate, GETDATE()) <= 7
            BEGIN
                SET @Score = 3;
                SET @Finding = 'DBCC CHECKDB job found and ran successfully in the last 7 days';
            END
            ELSE
            BEGIN
                SET @Score = 2;
                SET @Finding = 'DBCC CHECKDB job found but has not run successfully in the last 7 days';
            END
        END
        ELSE IF @LastRunStatus IS NOT NULL
        BEGIN
            SET @Score = 2;
            SET @Finding = 'DBCC CHECKDB job found but last execution failed (Status: ' + CAST(@LastRunStatus AS NVARCHAR(5)) + ')';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'DBCC CHECKDB job found but no execution history exists';
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;