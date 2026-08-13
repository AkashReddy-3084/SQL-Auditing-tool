-- Checklist: Audit logs stored in a tamper-resistant location (separate store / immutable)
-- Scope: SERVER
-- Scoring: 0 = No audits configured; 1 = Audits configured but stored in default local path; 2 = Audits configured with path indicating separate/secure storage (network share, different drive, or cloud); NOTE: True immutability requires OS/cloud verification.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DefaultDataDir NVARCHAR(256);
DECLARE @SeparateCount INT = 0;
DECLARE @DefaultCount INT = 0;

-- Get default data directory
SELECT @DefaultDataDir = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(256));
IF @DefaultDataDir IS NULL SET @DefaultDataDir = '';

-- Check if server file audits exist
IF OBJECT_ID('sys.server_file_audits') IS NOT NULL
BEGIN
    -- Count audits pointing to separate/cloud/network storage
    SELECT @SeparateCount = COUNT(*) FROM sys.server_file_audits 
    WHERE audit_file_path LIKE '\\%' 
       OR audit_file_path LIKE '%azure%' 
       OR audit_file_path LIKE '%blob%'
       OR (@DefaultDataDir <> '' AND audit_file_path NOT LIKE @DefaultDataDir + '%');

    -- Count audits pointing to default local storage
    SELECT @DefaultCount = COUNT(*) FROM sys.server_file_audits 
    WHERE audit_file_path NOT LIKE '\\%' 
       AND audit_file_path NOT LIKE '%azure%' 
       AND audit_file_path NOT LIKE '%blob%'
       AND (@DefaultDataDir = '' OR audit_file_path LIKE @DefaultDataDir + '%');

    -- Assign score based on findings (presence of secure storage takes precedence)
    IF @SeparateCount > 0
        SET @Score = 2;
    ELSE IF @DefaultCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.