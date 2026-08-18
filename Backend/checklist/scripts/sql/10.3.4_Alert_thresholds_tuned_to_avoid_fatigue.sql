-- Checklist: Alert thresholds tuned to avoid fatigue
-- Scope: SERVER
-- Scoring: 0: Any enabled alert has delay_between_responses = 0. 1: All enabled alerts have delay > 0 but < 60s. 2: All enabled alerts have delay >= 60s but < 300s. 3: All enabled alerts have delay >= 300s or no enabled alerts exist.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database does not support SQL Agent alerts. Alert thresholds are managed externally via Azure Monitor/Action Groups.';
END
ELSE
BEGIN
    DECLARE @TotalEnabled INT;
    DECLARE @ZeroDelay INT;
    DECLARE @LowDelay INT;
    DECLARE @MedDelay INT;

    SELECT 
        @TotalEnabled = COUNT(*),
        @ZeroDelay = SUM(CASE WHEN delay_between_responses = 0 THEN 1 ELSE 0 END),
        @LowDelay = SUM(CASE WHEN delay_between_responses > 0 AND delay_between_responses < 60 THEN 1 ELSE 0 END),
        @MedDelay = SUM(CASE WHEN delay_between_responses >= 60 AND delay_between_responses < 300 THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1;

    IF @TotalEnabled IS NULL OR @TotalEnabled = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No enabled SQL Agent alerts found. Alert fatigue risk is minimal.';
    END
    ELSE IF @ZeroDelay > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Alert fatigue risk: ' + CAST(@ZeroDelay AS NVARCHAR(10)) + ' enabled alert(s) have delay_between_responses = 0.';
    END
    ELSE IF @LowDelay > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Partial tuning: ' + CAST(@LowDelay AS NVARCHAR(10)) + ' enabled alert(s) have delay_between_responses between 1 and 59 seconds.';
    END
    ELSE IF @MedDelay > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Mostly tuned: ' + CAST(@MedDelay AS NVARCHAR(10)) + ' enabled alert(s) have delay_between_responses between 60 and 299 seconds.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'All ' + CAST(@TotalEnabled AS NVARCHAR(10)) + ' enabled alert(s) have delay_between_responses >= 300 seconds. Thresholds are well-tuned to avoid fatigue.';
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;