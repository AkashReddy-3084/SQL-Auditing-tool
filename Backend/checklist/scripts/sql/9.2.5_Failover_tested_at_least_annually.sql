-- Checklist: Failover tested at least annually
-- Scope: SERVER
-- Scoring: 0=No evidence found, 1=Evidence exists but >12 months old, 2=Evidence within 12 months (proxy/indirect), 3=Explicit success confirmation within 12 months
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @LastRunDate INT;
DECLARE @LastRunStatus INT;
DECLARE @IsOnPrem BIT = 0;

-- Detect platform: msdb exists on-prem and Azure SQL MI, but not Azure SQL DB
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL SET @IsOnPrem = 1;

IF @IsOnPrem = 1
BEGIN
    -- Look for SQL Agent jobs related to failover/DR testing
    SELECT TOP 1
        @LastRunDate = jh.run_date,
        @LastRunStatus = jh.run_status
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
    WHERE (j.name LIKE '%failover%' OR j.name LIKE '%dr%' OR j.name LIKE '%test%')
      AND jh.step_id = 0 -- Job completion record
    ORDER BY jh.run_date DESC, jh.run_time DESC;

    IF @LastRunDate IS NOT NULL
    BEGIN
        IF DATEDIFF(DAY, CAST(CAST(@LastRunDate AS CHAR(8)) AS DATETIME), GETDATE()) <= 365
        BEGIN
            IF @LastRunStatus = 1 SET @Score = 3;
            ELSE SET @Score = 2;
        END
        ELSE
        BEGIN
            SET @Score = 1;
        END
    END
END
ELSE
BEGIN
    -- Azure SQL DB: No SQL Agent. Failover testing is managed via portal/CLI.
    -- Degrade gracefully; score remains 0.
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;