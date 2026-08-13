DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @LinkedServerCount INT = 0;
DECLARE @CredentialCount INT = 0;
DECLARE @JobCount INT = 0;

-- Check for Purview/Catalog linked servers (Server-level)
SELECT @LinkedServerCount = COUNT(*) FROM sys.linked_servers WHERE name LIKE '%purview%' OR name LIKE '%catalog%' OR provider LIKE '%purview%';

-- Check for Purview/Catalog server credentials (Server-level)
SELECT @CredentialCount = COUNT(*) FROM sys.credentials WHERE name LIKE '%purview%' OR name LIKE '%catalog%';

-- Check for catalog sync jobs in SQL Agent (Server-level, safe for missing Agent)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE '%purview%' OR name LIKE '%catalog%' OR name LIKE '%lineage%';

-- Scoring logic aligned with checklist definitions
-- 0 = No evidence
-- 1 = Indirect evidence (e.g., external access enabled or generic tags)
-- 2 = Partial integration (Purview-linked servers, credentials, or sync jobs detected)
-- 3 = Full technical integration (active endpoints + sync jobs + credentials verified)
DECLARE @MatchCount INT = 0;
IF @LinkedServerCount > 0 SET @MatchCount = @MatchCount + 1;
IF @CredentialCount > 0 SET @MatchCount = @MatchCount + 1;
IF @JobCount > 0 SET @MatchCount = @MatchCount + 1;

IF @MatchCount = 0 SET @Score = 0;
ELSE IF @MatchCount = 1 SET @Score = 1;
ELSE IF @MatchCount = 2 SET @Score = 2;
ELSE IF @MatchCount >= 3 SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;