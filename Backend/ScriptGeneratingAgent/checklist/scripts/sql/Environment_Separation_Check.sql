-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scoring: 0 = No environment indicators found. 1 = Partial evidence (DB names contain env keywords, server name does not). 2 = Strong evidence (Server/Instance name contains env keyword). Max score capped at 2 per partial-evidence rules.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ServerName NVARCHAR(128) = CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(128)) + N'\' + ISNULL(CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(128)), N'MSSQLSERVER');
DECLARE @EnvKeywords TABLE (Keyword NVARCHAR(10));
INSERT INTO @EnvKeywords VALUES ('DEV'), ('TEST'), ('PROD'), ('UAT'), ('STG'), ('QA'), ('SIT'), ('INT');

DECLARE @ServerMatch INT = 0;
SELECT @ServerMatch = COUNT(*) FROM @EnvKeywords k WHERE UPPER(@ServerName) LIKE '%' + UPPER(k.Keyword) + '%';

DECLARE @DbMatchCount INT = 0;
SELECT @DbMatchCount = COUNT(*) FROM sys.databases d
CROSS JOIN @EnvKeywords k
WHERE UPPER(d.name) LIKE '%' + UPPER(k.Keyword) + '%';

IF @ServerMatch > 0
BEGIN
    SET @Score = 2;
    SET @Result = 'Pass';
END
ELSE IF @DbMatchCount > 0
BEGIN
    SET @Score = 1;
    SET @Result = 'Pass';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Result = 'Fail';
END

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;