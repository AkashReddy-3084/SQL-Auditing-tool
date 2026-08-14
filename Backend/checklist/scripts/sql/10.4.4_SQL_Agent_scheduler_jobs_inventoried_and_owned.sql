-- Checklist: SQL Agent / scheduler jobs inventoried and owned
-- Scope: SERVER
-- Scoring: 0 = No jobs or 0% owned; 1 = 1-49% owned; 2 = 50-99% owned; 3 = 100% owned. Degrades to 1 if SQL Agent is unavailable.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalJobs INT = 0;
DECLARE @OwnedJobs INT = 0;

IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @TotalJobs = COUNT(*),
           @OwnedJobs = SUM(CASE WHEN owner_sid <> 0x0 THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysjobs;

    IF @TotalJobs > 0
    BEGIN
        IF @OwnedJobs = @TotalJobs SET @Score = 3;
        ELSE IF CAST(@OwnedJobs AS FLOAT) / @TotalJobs >= 0.5 SET @Score = 2;
        ELSE IF @OwnedJobs > 0 SET @Score = 1;
        ELSE SET @Score = 0;
    END
    ELSE
    BEGIN
        SET @Score = 0; -- No jobs to inventory
    END
END
ELSE
BEGIN
    SET @Score = 1; -- SQL Agent not available on this platform (e.g., Azure SQL DB)
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;