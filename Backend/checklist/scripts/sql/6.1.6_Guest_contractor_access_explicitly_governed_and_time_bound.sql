-- Checklist: Guest/contractor access explicitly governed and time-bound
-- Scope: SERVER
-- Scoring: 0=Fail, 1=Partial Pass, 2=Mostly Pass, 3=Pass
-- NOTE: SQL Server lacks native login expiration. Compliance relies on external governance (IAM/PIM) and role restrictions.
-- Max score is capped at 2 per checklist scoring logic when guest logins exist.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalGuests INT = 0;
DECLARE @SysadminGuests INT = 0;

-- Identify potential guest/contractor logins via naming conventions
SELECT @TotalGuests = COUNT(*)
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U')
  AND (LOWER(sp.name) LIKE '%guest%' OR LOWER(sp.name) LIKE '%contractor%' OR LOWER(sp.name) LIKE '%temp%' 
    OR LOWER(sp.name) LIKE '%ext%' OR LOWER(sp.name) LIKE '%vendor%' OR LOWER(sp.name) LIKE '%consultant%');

IF @TotalGuests = 0
BEGIN
    SET @Score = 3;
END
ELSE
BEGIN
    -- Count guests with sysadmin role (primary restriction check)
    SELECT @SysadminGuests = COUNT(*)
    FROM sys.server_principals sp
    JOIN sys.server_role_members srm ON sp.principal_id = srm.member_principal_id
    JOIN sys.server_principals sr ON srm.role_principal_id = sr.principal_id
    WHERE sp.type IN ('S', 'U')
      AND (LOWER(sp.name) LIKE '%guest%' OR LOWER(sp.name) LIKE '%contractor%' OR LOWER(sp.name) LIKE '%temp%' 
        OR LOWER(sp.name) LIKE '%ext%' OR LOWER(sp.name) LIKE '%vendor%' OR LOWER(sp.name) LIKE '%consultant%')
      AND sr.name = 'sysadmin';

    DECLARE @CompliantGuests INT = @TotalGuests - @SysadminGuests;

    IF @SysadminGuests > 0
        SET @Score = 0;
    ELSE IF @CompliantGuests = @TotalGuests
        SET @Score = 2; -- Capped at 2 per checklist: platform lacks native expiration support
    ELSE IF @CompliantGuests > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;