-- Checklist: Server/database topology documented (instances, databases, elastic pools)
-- Scoring: 0 = Fail (Cannot enumerate topology or critical system views are inaccessible), 1 = Partial Pass (Topology successfully enumerated but no internal documentation artifacts found), 2 = Mostly Pass (Topology fully enumerated with extended properties/metadata present, serving as an automated documentation baseline. Max score capped at 2 per partial-evidence rule.)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbCount INT = 0;
DECLARE @DocCount INT = 0;

-- Count accessible user databases
SELECT @DbCount = COUNT(*) FROM sys.databases WHERE state = 0 AND database_id > 4;

-- Check for extended properties on databases (proxy for internal documentation)
SELECT @DocCount = COUNT(*) FROM sys.extended_properties ep
JOIN sys.databases d ON ep.major_id = d.database_id
WHERE ep.class = 0 AND d.database_id > 4;

-- Evaluate
IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Result = 'Fail';
END
ELSE IF @DocCount = 0
BEGIN
    SET @Score = 1;
    SET @Result = 'Partial Pass';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Result = 'Mostly Pass';
END

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;