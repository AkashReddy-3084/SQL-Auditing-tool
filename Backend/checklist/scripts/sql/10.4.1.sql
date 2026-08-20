-- Checklist: ETL/job run history captured and retained
-- Scope: SERVER
-- Scoring: 3 = history > 30 days; 2 = history 7-30 days; 1 = history < 7 days; 0 = no history/jobs

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No job history found';

DECLARE @MinDate INT;
DECLARE @MaxDate INT;
DECLARE @DaysDiff INT;

-- Azure SQL Database does not have SQL Agent; it is managed by the platform (Elastic Jobs/Azure Data Factory)
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Agent is not applicable; job orchestration is managed by platform services';
END
ELSE
BEGIN
    -- Check for the existence of job history in msdb
    SELECT 
        @MinDate = MIN(run_date), 
        @MaxDate = MAX(run_date) 
    FROM msdb.dbo.sysjobhistory;

    -- Convert integer dates (YYYYMMDD) to actual dates for calculation
    IF @MinDate IS NOT NULL
    BEGIN
        -- Convert YYYYMMDD integer to DATE
        DECLARE @StartDate DATE = CAST(CAST(@MinDate AS VARCHAR(8)) AS DATE);
        DECLARE @EndDate DATE = CAST(CAST(@MaxDate AS VARCHAR(8)) AS DATE);
        
        SET @DaysDiff = DATEDIFF(DAY, @StartDate, @EndDate);

        IF @DaysDiff > 30
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Job history retained for ' + CAST(@DaysDiff AS VARCHAR) + ' days';
        END
        ELSE IF @DaysDiff >= 7
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Job history retained for ' + CAST(@DaysDiff AS VARCHAR) + ' days';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Job history retained for only ' + CAST(@DaysDiff AS VARCHAR) + ' days';
        END
    END
    ELSE
    BEGIN
        -- Check if jobs even exist
        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs)
        BEGIN
            SET @Score = 0;
            SET @Finding = 'Jobs are configured but no execution history was found';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'No SQL Agent jobs configured';
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;