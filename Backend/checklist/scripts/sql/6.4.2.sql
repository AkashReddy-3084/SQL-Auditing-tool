-- Checklist: No credentials hardcoded in ETL packages, scripts, or linked servers
-- Scope: SERVER
-- Scoring: 3 = no hardcoded credentials found; 2 = 1-2 suspected patterns; 1 = multiple suspected patterns; 0 = clear evidence of hardcoded passwords in linked servers.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT = 3;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No hardcoded credentials detected';

DECLARE @SuspectCount INT = 0;
DECLARE @Evidence NVARCHAR(MAX) = '';

-- 1. Check Linked Servers for hardcoded remote logins
-- We check for non-null remote logins as a proxy for credential configuration.
DECLARE @LS_Evidence NVARCHAR(MAX) = '';
SELECT @LS_Evidence = STRING_AGG(CAST('Linked Server: ' + name + ' uses remote login ' + ISNULL(remote_name, 'NULL') AS NVARCHAR(MAX)), '; ')
FROM sys.servers 
WHERE is_linked = 1 AND remote_name IS NOT NULL;

IF @LS_Evidence IS NOT NULL
BEGIN
    SET @SuspectCount = @SuspectCount + 1;
    SET @Evidence = @LS_Evidence;
END

-- 2. Check SQL Agent Job Steps for common credential keywords (Password, Pwd, Secret, UserID)
DECLARE @JobStepEvidence NVARCHAR(MAX) = '';
SELECT @JobStepEvidence = STRING_AGG(CAST('Job: ' + j.name + ' Step: ' + CAST(s.step_id AS NVARCHAR(10)) + ' contains keyword ' + 
    CASE 
        WHEN s.command LIKE '%password%' THEN 'password'
        WHEN s.command LIKE '%pwd%' THEN 'pwd'
        WHEN s.command LIKE '%secret%' THEN 'secret'
        WHEN s.command LIKE '%userid%' THEN 'userid'
    END AS NVARCHAR(MAX)), '; ')
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON s.job_id = j.job_id
WHERE s.command LIKE '%password%' 
   OR s.command LIKE '%pwd%' 
   OR s.command LIKE '%secret%' 
   OR s.command LIKE '%userid%';

IF @JobStepEvidence IS NOT NULL
BEGIN
    SET @SuspectCount = @SuspectCount + 1;
    SET @Evidence = ISNULL(@Evidence + '; ', '') + @JobStepEvidence;
END

-- Scoring Logic
IF @SuspectCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No hardcoded credentials or suspect keywords detected in linked servers or job steps.';
END
ELSE IF @SuspectCount = 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Minor suspicion: ' + @Evidence;
END
ELSE IF @SuspectCount > 1
BEGIN
    SET @Score = 1;
    SET @Finding = 'Multiple suspect patterns found: ' + @Evidence;
END

-- Check for clear evidence of hardcoded passwords in linked servers (Score 0)
-- In T-SQL, we can check if the linked server is configured to use a specific remote login/password combination
-- via sys.servers or by checking for common patterns in the remote login name itself.
IF EXISTS (SELECT 1 FROM sys.servers WHERE is_linked = 1 AND remote_name LIKE '%password%' OR remote_name LIKE '%pwd%')
BEGIN
    SET @Score = 0;
    SET @Finding = 'Clear evidence of hardcoded passwords found in linked server remote login names: ' + @Evidence;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;