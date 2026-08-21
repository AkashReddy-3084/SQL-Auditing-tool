-- Checklist: Guest/contractor access explicitly governed and time-bound
-- Scope: SERVER
-- Scoring: 0: No accounts found or all identified accounts lack time-bound controls. 1: Mixed governance; some accounts have controls, others lack them. 2: All accounts show time-bound governance, but some rely on indirect proxies (e.g., recent creation). 3: All identified accounts have explicit time-bound controls (expiration enforced or disabled).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @GuestLogins TABLE (
    LoginName NVARCHAR(256),
    IsExpiredChecked BIT,
    IsDisabled BIT,
    DaysOld INT,
    GovernanceStatus NVARCHAR(50)
);

INSERT INTO @GuestLogins
SELECT 
    sp.name,
    ISNULL(slo.is_expiration_checked, 0),
    sp.is_disabled,
    ISNULL(DATEDIFF(day, sp.create_date, GETDATE()), 9999),
    CASE 
        WHEN sp.is_disabled = 1 THEN 'Disabled'
        WHEN ISNULL(slo.is_expiration_checked, 0) = 1 THEN 'Expiration Enforced'
        WHEN ISNULL(DATEDIFF(day, sp.create_date, GETDATE()), 9999) <= 90 THEN 'Recent Creation'
        ELSE 'No Time-Bound Control'
    END AS GovernanceStatus
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins slo ON sp.principal_id = slo.principal_id
WHERE sp.type IN ('S', 'U')
  AND (sp.name LIKE '%guest%' OR sp.name LIKE '%contractor%' OR sp.name LIKE '%temp%')
  AND sp.name NOT LIKE '##%';

DECLARE @Total INT = (SELECT COUNT(*) FROM @GuestLogins);
DECLARE @Explicit INT = (SELECT COUNT(*) FROM @GuestLogins WHERE GovernanceStatus IN ('Disabled', 'Expiration Enforced'));
DECLARE @Proxy INT = (SELECT COUNT(*) FROM @GuestLogins WHERE GovernanceStatus = 'Recent Creation');
DECLARE @None INT = (SELECT COUNT(*) FROM @GuestLogins WHERE GovernanceStatus = 'No Time-Bound Control');

IF @Total = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No guest/contractor accounts identified. Cannot verify time-bound governance.';
END
ELSE IF @None = 0 AND @Proxy = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'All ' + CAST(@Total AS NVARCHAR) + ' identified guest/contractor account(s) have explicit time-bound controls.';
END
ELSE IF @None = 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'All ' + CAST(@Total AS NVARCHAR) + ' account(s) show time-bound governance. ' + CAST(@Proxy AS NVARCHAR) + ' rely on indirect proxies (recent creation).';
END
ELSE IF @Explicit + @Proxy > 0
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@Total AS NVARCHAR) + ' account(s) found. ' + CAST(@None AS NVARCHAR) + ' lack time-bound controls: ' + 
        (SELECT STRING_AGG(LoginName, ', ') FROM @GuestLogins WHERE GovernanceStatus = 'No Time-Bound Control');
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CAST(@Total AS NVARCHAR) + ' account(s) found. All lack time-bound controls: ' + 
        (SELECT STRING_AGG(LoginName, ', ') FROM @GuestLogins);
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;