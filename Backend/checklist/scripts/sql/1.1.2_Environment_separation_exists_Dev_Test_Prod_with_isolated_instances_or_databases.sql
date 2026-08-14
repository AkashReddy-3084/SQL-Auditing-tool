-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scope: SERVER
-- Scoring: 0=No environment indicators; 1=Partial indicators (server OR DBs only); 2=Clear server environment label but inconsistent DB naming; 3=Clear server label AND consistent DB naming alignment
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ServerName NVARCHAR(256);
DECLARE @EnvKeyword NVARCHAR(20) = NULL;
DECLARE @DbCount INT = 0;
DECLARE @MatchingDbCount INT = 0;

-- Get full server name (works on-prem and Azure SQL)
SET @ServerName = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), '');

-- Detect environment keyword in server name
IF LOWER(@ServerName) LIKE '%dev%' SET @EnvKeyword = 'dev';
ELSE IF LOWER(@ServerName) LIKE '%test%' SET @EnvKeyword = 'test';
ELSE IF LOWER(@ServerName) LIKE '%prod%' SET @EnvKeyword = 'prod';
ELSE IF LOWER(@ServerName) LIKE '%qa%' SET @EnvKeyword = 'qa';
ELSE IF LOWER(@ServerName) LIKE '%uat%' SET @EnvKeyword = 'uat';
ELSE IF LOWER(@ServerName) LIKE '%staging%' SET @EnvKeyword = 'staging';
ELSE IF LOWER(@ServerName) LIKE '%preprod%' SET @EnvKeyword = 'preprod';

-- Count user databases and those matching the detected keyword
SELECT @DbCount = COUNT(*),
       @MatchingDbCount = ISNULL(SUM(CASE WHEN LOWER(name) LIKE '%' + @EnvKeyword + '%' THEN 1 ELSE 0 END), 0)
FROM sys.databases
WHERE database_id > 4 AND state = 0;

-- Scoring logic
IF @EnvKeyword IS NOT NULL AND @DbCount > 0
BEGIN
    IF CAST(@MatchingDbCount AS FLOAT) / @DbCount >= 0.8
        SET @Score = 3;
    ELSE IF CAST(@MatchingDbCount AS FLOAT) / @DbCount >= 0.3
        SET @Score = 2;
    ELSE
        SET @Score = 1;
END
ELSE IF @EnvKeyword IS NULL
BEGIN
    -- Fallback: Check if DBs have environment keywords even if server name lacks them
    SELECT @MatchingDbCount = ISNULL(SUM(CASE
        WHEN LOWER(name) LIKE '%dev%' OR LOWER(name) LIKE '%test%' OR LOWER(name) LIKE '%prod%' OR LOWER(name) LIKE '%qa%' OR LOWER(name) LIKE '%uat%' THEN 1
        ELSE 0
    END), 0)
    FROM sys.databases WHERE database_id > 4 AND state = 0;

    IF @MatchingDbCount > 0 SET @Score = 1;
    ELSE SET @Score = 0;
END
ELSE
BEGIN
    -- Server has environment keyword but no user databases exist
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;