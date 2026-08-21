-- Checklist: Login/permission changes captured and reviewable
-- Scope: SERVER
-- Scoring: 0: No enabled server audit or platform lacks T-SQL server audit support. 1: Audit enabled but tracks zero relevant login/permission groups. 2: Audit enabled and tracks 1-2 relevant groups. 3: Audit enabled and tracks all 3 relevant groups (principal, role member, permission changes).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @Finding = 'Azure SQL Database does not expose server-level audit specifications via T-SQL. Verify login/permission auditing via Azure Portal or Azure Resource Manager.';
END
ELSE
BEGIN
    DECLARE @EnabledCount INT = 0;
    DECLARE @GroupsTracked NVARCHAR(MAX) = '';

    SELECT @EnabledCount = COUNT(DISTINCT sa.name),
           @GroupsTracked = STRING_AGG(DISTINCT sas.audit_action_id, ', ') WITHIN GROUP (ORDER BY sas.audit_action_id)
    FROM sys.server_audits sa
    JOIN sys.server_audit_specifications sas ON sa.audit_guid = sas.audit_guid
    WHERE sa.is_state_enabled = 1 
      AND sas.is_state_enabled = 1
      AND sas.audit_action_id IN ('SERVER_PRINCIPAL_CHANGE_GROUP', 'SERVER_ROLE_MEMBER_CHANGE_GROUP', 'SERVER_OBJECT_PERMISSION_CHANGE_GROUP');

    IF @EnabledCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No enabled server audit specifications found tracking login or permission changes.';
    END
    ELSE
    BEGIN
        DECLARE @Principal INT = CASE WHEN @GroupsTracked LIKE '%SERVER_PRINCIPAL_CHANGE_GROUP%' THEN 1 ELSE 0 END;
        DECLARE @RoleMember INT = CASE WHEN @GroupsTracked LIKE '%SERVER_ROLE_MEMBER_CHANGE_GROUP%' THEN 1 ELSE 0 END;
        DECLARE @PermChange INT = CASE WHEN @GroupsTracked LIKE '%SERVER_OBJECT_PERMISSION_CHANGE_GROUP%' THEN 1 ELSE 0 END;
        DECLARE @TotalGroups INT = @Principal + @RoleMember + @PermChange;

        IF @TotalGroups = 3
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Fully covered: ' + @GroupsTracked + ' tracked by ' + CAST(@EnabledCount AS NVARCHAR(10)) + ' enabled audit(s).';
        END
        ELSE IF @TotalGroups >= 1
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Partial coverage: ' + @GroupsTracked + ' tracked by ' + CAST(@EnabledCount AS NVARCHAR(10)) + ' enabled audit(s). Missing groups may leave gaps.';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Audit enabled but does not track login/permission change groups.';
        END
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;