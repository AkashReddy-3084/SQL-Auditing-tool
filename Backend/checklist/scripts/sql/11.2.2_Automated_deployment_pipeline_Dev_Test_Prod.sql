-- Checklist: Automated deployment pipeline (Dev → Test → Prod)
-- Scope: SERVER
-- Scoring: 0: No evidence. 1: Limited evidence (single job/account). 2: Good evidence (multiple jobs/accounts or scheduled automation). NOTE: Proxy evidence is capped at 2 per system rules.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @JobCount INT = 0;
DECLARE @AccountCount INT = 0;
DECLARE @JobNames NVARCHAR(MAX) = 'None';
DECLARE @AccountNames NVARCHAR(MAX) = 'None';
DECLARE @EnabledJobCount INT = 0;

-- Check SQL Agent Jobs for deployment patterns (SQL Server / Azure SQL MI only)
IF @EngineEdition <> 5
BEGIN
    SELECT @JobCount = COUNT(1),
           @JobNames = ISNULL(STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name), 'None')
    FROM msdb.dbo.sysjobs
    WHERE name LIKE '%deploy%' OR name LIKE '%release%' OR name LIKE '%ci%' OR name LIKE '%cd%' OR name LIKE '%pipeline%';

    SELECT @EnabledJobCount = COUNT(1)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1
      AND (name LIKE '%deploy%' OR name LIKE '%release%' OR name LIKE '%ci%' OR name LIKE '%cd%' OR name LIKE '%pipeline%');
END
ELSE
BEGIN
    SET @JobNames = 'N/A (Azure SQL DB)';
END

-- Check Logins/Users for CI/CD service accounts
IF @EngineEdition <> 5
BEGIN
    SELECT @AccountCount = COUNT(1),
           @AccountNames = ISNULL(STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name), 'None')
    FROM sys.server_principals
    WHERE type IN ('S', 'U')
      AND (name LIKE '%ci%' OR name LIKE '%cd%' OR name LIKE '%deploy%' OR name LIKE '%automation%' OR name LIKE '%pipeline%');
END
ELSE
BEGIN
    SELECT @AccountCount = COUNT(1),
           @AccountNames = ISNULL(STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name), 'None')
    FROM sys.database_principals
    WHERE type IN ('S', 'U', 'K')
      AND (name LIKE '%ci%' OR name LIKE '%cd%' OR name LIKE '%deploy%' OR name LIKE '%automation%' OR name LIKE '%pipeline%');
END

SET @Score = 0;
IF @JobCount > 0 OR @AccountCount > 0
BEGIN
    SET @Score = 1;
    IF @JobCount >= 2 OR @AccountCount >= 2 OR @EnabledJobCount > 0
    BEGIN
        SET @Score = 2;
    END
END
-- Proxy evidence cap per system rules
IF @Score > 2 SET @Score = 2;

SET @DatabaseQueried = 'master';

SET @Finding = CASE 
    WHEN @Score = 0 THEN 'No deployment-related SQL Agent jobs or CI/CD service accounts found.'
    WHEN @Score = 1 THEN 'Limited evidence found. Jobs: ' + @JobNames + '; Accounts: ' + @AccountNames + '.'
    WHEN @Score = 2 THEN 'Good evidence found. ' + CAST(@JobCount AS NVARCHAR(10)) + ' deployment jobs: ' + @JobNames + '; ' + CAST(@AccountCount AS NVARCHAR(10)) + ' CI/CD accounts: ' + @AccountNames + '.'
END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Finding = @Finding + ' NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;