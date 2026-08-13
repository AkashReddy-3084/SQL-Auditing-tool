-- Checklist: Page verification set to CHECKSUM
-- Scope: SERVER
-- Scoring: 3 = All user databases set to CHECKSUM; 2 = At least one user database set to CHECKSUM but not all; 1 = No CHECKSUM but some use TORN_PAGE_DETECTION; 0 = No CHECKSUM or TORN_PAGE_DETECTION found.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalUserDbs INT;
DECLARE @ChecksumCount INT;
DECLARE @TornPageCount INT;

SELECT @TotalUserDbs = COUNT(*),
       @ChecksumCount = SUM(CASE WHEN page_verify_option_desc = 'CHECKSUM' THEN 1 ELSE 0 END),
       @TornPageCount = SUM(CASE WHEN page_verify_option_desc = 'TORN_PAGE_DETECTION' THEN 1 ELSE 0 END)
FROM sys.databases
WHERE database_id > 4 AND state = 0;

IF @TotalUserDbs = 0
BEGIN
    SET @Score = 3; -- No user databases to check, considered compliant
END
ELSE IF @ChecksumCount = @TotalUserDbs
BEGIN
    SET @Score = 3;
END
ELSE IF @ChecksumCount > 0
BEGIN
    SET @Score = 2;
END
ELSE IF @TornPageCount > 0
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;