-- Checklist: MAXDOP and cost threshold for parallelism set deliberately
-- Scope: SERVER
-- Scoring: 0=Both at defaults (MAXDOP=0, Cost=5), 1=One changed from default, 2=Both changed from default, 3=Both changed and within best practices (MAXDOP 1-8, Cost 50-100)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MaxDopVal INT = 0;
DECLARE @CostThreshVal INT = 0;

SELECT @MaxDopVal = CONVERT(INT, value) FROM sys.configurations WHERE name = 'max degree of parallelism';
SELECT @CostThreshVal = CONVERT(INT, value) FROM sys.configurations WHERE name = 'cost threshold for parallelism';

DECLARE @MaxDopDeliberate BIT = CASE WHEN @MaxDopVal > 0 THEN 1 ELSE 0 END;
DECLARE @CostDeliberate BIT = CASE WHEN @CostThreshVal > 5 THEN 1 ELSE 0 END;

IF @MaxDopDeliberate = 1 AND @CostDeliberate = 1
BEGIN
    SET @Score = 2;
    IF @MaxDopVal BETWEEN 1 AND 8 AND @CostThreshVal BETWEEN 50 AND 100
        SET @Score = 3;
END
ELSE IF @MaxDopDeliberate = 1 OR @CostDeliberate = 1
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;