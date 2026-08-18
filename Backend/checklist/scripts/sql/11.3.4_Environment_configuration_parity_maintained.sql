-- Checklist: Environment configuration parity maintained
-- Scope: SERVER
-- Scoring: Score 3: 100% match. Score 2: 80-99% match. Score 1: 50-79% match. Score 0: <50% match or no settings available.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

-- Baseline of critical configuration settings for parity verification.
-- Values represent recommended production standards; update to match your organization's baseline.
DECLARE @Baseline TABLE (ConfigName NVARCHAR(128), ExpectedValue INT);
INSERT INTO @Baseline VALUES
('backup compression default', 1),
('cost threshold for parallelism', 50),
('max degree of parallelism', 0),
('optimize for ad hoc workloads', 1),
('remote query timeout (sec)', 600),
('user options', 0);

DECLARE @Evaluated TABLE (ConfigName NVARCHAR(128), ExpectedValue INT, ActualValue INT, IsMatch BIT);

BEGIN TRY
    INSERT INTO @Evaluated
    SELECT b.ConfigName, b.ExpectedValue, c.value_in_use, CASE WHEN c.value_in_use = b.ExpectedValue THEN 1 ELSE 0 END
    FROM @Baseline b
    INNER JOIN sys.configurations c ON b.ConfigName = c.name;
END TRY
BEGIN CATCH
    INSERT INTO @Evaluated (ConfigName, ExpectedValue, ActualValue, IsMatch)
    SELECT ConfigName, ExpectedValue, NULL, 0 FROM @Baseline;
END TRY

DECLARE @TotalChecked INT = (SELECT COUNT(*) FROM @Evaluated);
DECLARE @Matches INT = (SELECT COUNT(*) FROM @Evaluated WHERE IsMatch = 1);

IF @TotalChecked = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No configurable settings found for evaluation. Parity cannot be verified.';
END
ELSE
BEGIN
    SET @Score = CASE
        WHEN @Matches = @TotalChecked THEN 3
        WHEN @Matches >= CAST(@TotalChecked * 0.8 AS INT) THEN 2
        WHEN @Matches >= CAST(@TotalChecked * 0.5 AS INT) THEN 1
        ELSE 0
    END;

    SELECT @Finding = STRING_AGG(
        CASE WHEN IsMatch = 0 THEN ConfigName + ' = ' + CAST(ActualValue AS NVARCHAR(10)) + ' (expected ' + CAST(ExpectedValue AS NVARCHAR(10)) + ')' ELSE NULL END,
        ', '
    ) FROM @Evaluated;

    IF @Finding IS NULL SET @Finding = 'All evaluated settings match the production baseline.';
    ELSE SET @Finding = 'Configuration drift detected: ' + @Finding;
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;