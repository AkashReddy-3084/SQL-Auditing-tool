-- Checklist: Credential/key rotation policy defined and automated
-- Scope: SERVER
-- Scoring: 3 = no enabled SQL logins, or every one enforces password policy and expiration with no password older than 365 days and no certificate expiring within 90 days; 2 = at least 90% enforce both settings and under 10% are stale; 1 = only partial enforcement, stale passwords or expiring keys; 0 = no enforcement at all, or login metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Credential and key rotation metadata was not readable';
DECLARE @Logins INT = -1;
DECLARE @Enforced INT = 0;
DECLARE @Stale INT = 0;
DECLARE @StaleNames NVARCHAR(MAX) = 'none';
DECLARE @ExpiringKeys INT = 0;
DECLARE @SymKeys INT = 0;
DECLARE @Jobs INT = 0;
DECLARE @EnforcedRatio DECIMAL(9, 4) = 0;
DECLARE @StaleRatio DECIMAL(9, 4) = 0;
DECLARE @Probe NVARCHAR(600);

BEGIN TRY
    SELECT @Logins = COUNT(*),
           @Enforced = ISNULL(SUM(CASE WHEN is_policy_checked = 1 AND is_expiration_checked = 1 THEN 1 ELSE 0 END), 0),
           @Stale = ISNULL(SUM(CASE WHEN DATEDIFF(day, CONVERT(DATETIME, LOGINPROPERTY(name, 'PasswordLastSetTime')), GETDATE()) > 365 THEN 1 ELSE 0 END), 0),
           @StaleNames = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
                CASE WHEN DATEDIFF(day, CONVERT(DATETIME, LOGINPROPERTY(name, 'PasswordLastSetTime')), GETDATE()) > 365 THEN name END), ', '), 'none')
    FROM sys.sql_logins
    WHERE is_disabled = 0;
END TRY
BEGIN CATCH
    SET @Logins = -1;
END CATCH

BEGIN TRY
    SELECT @ExpiringKeys = ISNULL(SUM(CASE WHEN expiry_date <= DATEADD(day, 90, GETDATE()) THEN 1 ELSE 0 END), 0)
    FROM sys.certificates
    WHERE name NOT LIKE '##%';

    SELECT @SymKeys = COUNT(*) FROM sys.symmetric_keys WHERE name NOT LIKE '##%';
END TRY
BEGIN CATCH
    SET @ExpiringKeys = 0;
END CATCH

IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) <> 5
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @j = COUNT(*)
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1
  AND (j.name LIKE N''%rotat%'' OR j.name LIKE N''%credential%'' OR j.name LIKE N''%key%'');';
        EXEC sys.sp_executesql @Probe, N'@j INT OUTPUT', @j = @Jobs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Jobs = 0;
    END CATCH
END

SET @EnforcedRatio = CASE WHEN @Logins <= 0 THEN 0
                          ELSE CONVERT(DECIMAL(9, 4), @Enforced) / NULLIF(@Logins, 0) END;
SET @StaleRatio = CASE WHEN @Logins <= 0 THEN 0
                       ELSE CONVERT(DECIMAL(9, 4), @Stale) / NULLIF(@Logins, 0) END;

SET @Score = CASE
    WHEN @Logins = -1 THEN 0
    WHEN @Enforced = @Logins AND @Stale = 0 AND @ExpiringKeys = 0 THEN 3
    WHEN ISNULL(@EnforcedRatio, 0) >= 0.90 AND ISNULL(@StaleRatio, 1) < 0.10 THEN 2
    WHEN @Enforced > 0 OR @Jobs > 0 THEN 1
    ELSE 0 END;

SET @Finding = CASE
    WHEN @Logins = -1 THEN 'SQL login policy metadata could not be read with the current permissions'
    ELSE CONCAT('enabled SQL logins = ', @Logins,
                ', enforcing both password policy and expiration = ', @Enforced,
                ', with a password older than 365 days = ', @Stale,
                ' (', LEFT(@StaleNames, 300), ')',
                ', certificates expiring within 90 days = ', @ExpiringKeys,
                ', user symmetric keys = ', @SymKeys,
                ', enabled Agent jobs matching rotation naming = ', @Jobs)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
