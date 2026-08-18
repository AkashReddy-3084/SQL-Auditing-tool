-- Checklist: Credential/key rotation policy defined and automated
-- Scope: SERVER
-- Scoring: 0: No secrets or automation detected. 1: Secrets exist but no automation detected. 2: Automation detected; policy definition requires human verification. 3: Not achievable automatically.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @CredCount INT = 0;
DECLARE @CertCount INT = 0;
DECLARE @KeyCount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @JobNames NVARCHAR(MAX) = 'None';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT @CredCount = COUNT(*) FROM master.sys.credentials;
SELECT @CertCount = COUNT(*) FROM master.sys.certificates;
SELECT @KeyCount = COUNT(*) FROM master.sys.asymmetric_keys;

IF @EngineEdition <> 5 AND OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*), @JobNames = ISNULL(STRING_AGG(name, ', '), 'None')
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1
      AND (
        name LIKE '%rotate%' OR name LIKE '%credential%' OR name LIKE '%key%' OR 
        name LIKE '%password%' OR name LIKE '%secret%' OR name LIKE '%cert%'
      );
END

SET @DatabaseQueried = 'master';

IF @JobCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Automation detected for ' + CAST(@JobCount AS NVARCHAR(10)) + ' job(s): ' + @JobNames + '. Policy definition requires human verification.';
END
ELSE IF @CredCount > 0 OR @CertCount > 0 OR @KeyCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Credentials/keys exist (' + CAST(@CredCount AS NVARCHAR(10)) + ' credentials, ' + CAST(@CertCount AS NVARCHAR(10)) + ' certificates, ' + CAST(@KeyCount AS NVARCHAR(10)) + ' asymmetric keys) but no automation jobs detected.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No credentials, certificates, or asymmetric keys found, and no automation detected.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;