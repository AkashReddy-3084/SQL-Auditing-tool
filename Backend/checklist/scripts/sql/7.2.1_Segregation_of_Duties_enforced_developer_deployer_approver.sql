-- Checklist: Segregation of Duties enforced (developer ≠ deployer ≠ approver)
-- Scope: SERVER
-- Scoring: 0=No custom roles/separation, 1=Partial separation or overlaps detected, 2=Clear separation with distinct roles and no overlaps, 3=Fully verified (requires explicit SoD metadata)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('sys.server_principals') IS NOT NULL
BEGIN
    -- On-prem / Azure SQL MI path
    WITH CustomRoles AS (
        SELECT principal_id, name
        FROM sys.server_principals
        WHERE type = 'R' AND is_fixed_role = 0
    ),
    RoleMembers AS (
        SELECT
            l.name AS PrincipalName,
            r.name AS RoleName,
            CASE
                WHEN r.name LIKE '%dev%' OR r.name LIKE '%developer%' THEN 'DEV'
                WHEN r.name LIKE '%deploy%' OR r.name LIKE '%release%' THEN 'DEPLOY'
                WHEN r.name LIKE '%approv%' OR r.name LIKE '%control%' OR r.name LIKE '%sox%' THEN 'APPROVE'
                ELSE 'OTHER'
            END AS DutyCategory
        FROM sys.server_role_members rm
        JOIN sys.server_principals l ON rm.member_principal_id = l.principal_id
        JOIN CustomRoles r ON rm.role_principal_id = r.principal_id
    ),
    Overlaps AS (
        SELECT PrincipalName, COUNT(DISTINCT DutyCategory) AS CategoryCount
        FROM RoleMembers
        WHERE DutyCategory != 'OTHER'
        GROUP BY PrincipalName
        HAVING COUNT(DISTINCT DutyCategory) > 1
    )
    SELECT @Score = CASE
        WHEN (SELECT COUNT(*) FROM CustomRoles) = 0 THEN 0
        WHEN EXISTS (SELECT 1 FROM Overlaps) THEN 1
        WHEN (SELECT COUNT(DISTINCT DutyCategory) FROM RoleMembers WHERE DutyCategory != 'OTHER') >= 3 THEN 2
        ELSE 1
    END;
END
ELSE
BEGIN
    -- Azure SQL DB fallback (no server roles)
    WITH CustomRoles AS (
        SELECT principal_id, name
        FROM sys.database_principals
        WHERE type = 'R' AND is_fixed_role = 0
    ),
    RoleMembers AS (
        SELECT
            u.name AS PrincipalName,
            r.name AS RoleName,
            CASE
                WHEN r.name LIKE '%dev%' OR r.name LIKE '%developer%' THEN 'DEV'
                WHEN r.name LIKE '%deploy%' OR r.name LIKE '%release%' THEN 'DEPLOY'
                WHEN r.name LIKE '%approv%' OR r.name LIKE '%control%' OR r.name LIKE '%sox%' THEN 'APPROVE'
                ELSE 'OTHER'
            END AS DutyCategory
        FROM sys.database_role_members rm
        JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
        JOIN CustomRoles r ON rm.role_principal_id = r.principal_id
    ),
    Overlaps AS (
        SELECT PrincipalName, COUNT(DISTINCT DutyCategory) AS CategoryCount
        FROM RoleMembers
        WHERE DutyCategory != 'OTHER'
        GROUP BY PrincipalName
        HAVING COUNT(DISTINCT DutyCategory) > 1
    )
    SELECT @Score = CASE
        WHEN (SELECT COUNT(*) FROM CustomRoles) = 0 THEN 0
        WHEN EXISTS (SELECT 1 FROM Overlaps) THEN 1
        WHEN (SELECT COUNT(DISTINCT DutyCategory) FROM RoleMembers WHERE DutyCategory != 'OTHER') >= 3 THEN 2
        ELSE 1
    END;
END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;