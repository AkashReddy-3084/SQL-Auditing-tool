DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalAlerts INT = 0;
DECLARE @TunedAny INT = 0;
DECLARE @Tuned30 INT = 0;

IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT @TotalAlerts = COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1;
    
    IF @TotalAlerts > 0
    BEGIN
        SELECT @TunedAny = COUNT(*) FROM msdb.dbo.sysalerts 
        WHERE enabled = 1 AND delay_between_responses > 0 AND has_response_option = 1;
        
        SELECT @Tuned30 = COUNT(*) FROM msdb.dbo.sysalerts 
        WHERE enabled = 1 AND delay_between_responses >= 30 AND has_response_option = 1;
        
        IF @Tuned30 = @TotalAlerts
            SET @Score = 3;
        ELSE IF @TunedAny > (@TotalAlerts / 2.0)
            SET @Score = 2;
        ELSE IF @TunedAny > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END
ELSE
BEGIN
    -- Azure SQL DB lacks SQL Agent; no alerts configured
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;