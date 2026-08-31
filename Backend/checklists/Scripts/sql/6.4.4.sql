-- Checklist: Credential/key rotation policy defined and automated
-- Scope: SERVER
-- Scoring: 2 = enabled SQL logins have password policy and expiry enforcement; 1 = partial enforcement; 0 = no enabled SQL logins or metadata unavailable
-- NOTE: Automated evidence only; rotation policy and automation cadence require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Credential policy metadata could not be evaluated';
DECLARE @SqlLogins INT = 0;
DECLARE @StaleOver365 INT = 0;
DECLARE @ExpiryEnforced INT = 0;
DECLARE @PolicyEnforced INT = 0;

BEGIN TRY
    SELECT @SqlLogins = COUNT(*),
           @StaleOver365 = ISNULL(SUM(CASE WHEN LOGINPROPERTY(name, 'PasswordLastSetTime') IS NULL THEN 0 WHEN DATEDIFF(day, CAST(LOGINPROPERTY(name, 'PasswordLastSetTime') AS datetime), GETDATE()) > 365 THEN 1 ELSE 0 END), 0),
           @ExpiryEnforced = ISNULL(SUM(CASE WHEN is_expiration_checked = 1 THEN 1 ELSE 0 END), 0),
           @PolicyEnforced = ISNULL(SUM(CASE WHEN is_policy_checked = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.sql_logins WHERE is_disabled = 0;
    SET @Score = CASE WHEN @SqlLogins = 0 THEN 0 WHEN @ExpiryEnforced = @SqlLogins AND @PolicyEnforced = @SqlLogins AND @StaleOver365 = 0 THEN 2 WHEN @ExpiryEnforced > 0 OR @PolicyEnforced > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'sql_logins=' + CONVERT(NVARCHAR(20), @SqlLogins) + N', stale_over_365d=' + CONVERT(NVARCHAR(20), @StaleOver365) + N', expiry_enforced=' + CONVERT(NVARCHAR(20), @ExpiryEnforced) + N', policy_enforced=' + CONVERT(NVARCHAR(20), @PolicyEnforced);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read credential policy metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;