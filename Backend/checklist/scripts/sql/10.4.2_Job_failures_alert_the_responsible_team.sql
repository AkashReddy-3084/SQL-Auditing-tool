-- Checklist: Job failures alert the responsible team
-- Scope: SERVER
-- Scoring: 0=0% jobs notify on failure, 1=1-49%, 2=50-99%, 3=100%
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalJobs INT = 0;
DECLARE @AlertedJobs INT = 0;
DECLARE @Pct FLOAT = 0;

IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @TotalJobs = COUNT(*),
           @AlertedJobs = SUM(CASE WHEN (notify_level_email = 2 OR notify_level_page = 2 OR notify_level_netsend = 2) 
                                   AND notify_operator_id <> 0 THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysjobs;

    SET @Pct = CASE WHEN @TotalJobs > 0 THEN (@AlertedJobs * 100.0 / @TotalJobs) ELSE 0 END;

    SET @Score = CASE 
        WHEN @Pct = 100 THEN 3
        WHEN @Pct >= 50 THEN 2
        WHEN @Pct > 0 THEN 1
        ELSE 0
    END;
END
ELSE
BEGIN
    -- SQL Agent not available (e.g., Azure SQL DB). Degrade gracefully.
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;