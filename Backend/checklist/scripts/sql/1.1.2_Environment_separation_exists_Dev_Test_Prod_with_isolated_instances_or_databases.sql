-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scope: SERVER
-- Scoring: 3: Server name indicates environment. 2: Database names indicate environment separation. 1: Partial/ambiguous naming. 0: No environment indicators found.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ServerName NVARCHAR(256);

SET @ServerName = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));

-- Check server name for environment indicators
DECLARE @ServerEnvMatch BIT = 0;
IF LOWER(@ServerName) LIKE '%dev%' OR LOWER(@ServerName) LIKE '%test%' OR LOWER(@ServerName) LIKE '%prod%' OR 
   LOWER(@ServerName) LIKE '%qa%' OR LOWER(@ServerName) LIKE '%uat%' OR LOWER(@ServerName) LIKE '%staging%' OR 
   LOWER(@ServerName) LIKE '%sandbox%' OR LOWER(@ServerName) LIKE '%demo%'
BEGIN
    SET @ServerEnvMatch = 1;
END

-- Check databases for environment indicators
DECLARE @DbEnvMatches NVARCHAR(MAX) = '';
SELECT @DbEnvMatches = STRING_AGG(name, ', ')
FROM sys.databases
WHERE database_id > 4
  AND (LOWER(name) LIKE '%dev%' OR LOWER(name) LIKE '%test%' OR LOWER(name) LIKE '%prod%' OR 
       LOWER(name) LIKE '%qa%' OR LOWER(name) LIKE '%uat%' OR LOWER(name) LIKE '%staging%' OR 
       LOWER(name) LIKE '%sandbox%' OR LOWER(name) LIKE '%demo%');

IF @ServerEnvMatch = 1
BEGIN
    SET @Score = 3;
    SET @Finding = 'Server name indicates environment separation: ' + @ServerName;
END
ELSE IF @DbEnvMatches IS NOT NULL AND @DbEnvMatches <> ''
BEGIN
    SET @Score = 2;
    SET @Finding = 'Database names indicate environment separation: ' + @DbEnvMatches;
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No environment indicators found in server or database names.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;