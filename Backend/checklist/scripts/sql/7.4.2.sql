-- Checklist: Login/permission changes captured and reviewable
-- Scope: SERVER
-- Scoring: 3 = Active audit with security action groups; 2 = Active audit but missing specific security groups; 1 = Audit exists but is disabled; 0 = No audit configured

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No SQL Server Audit configured';

-- Temporary table to hold found audit groups
CREATE TABLE #AuditGroups (GroupName NVARCHAR(256));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: Audit is managed by the platform (Azure SQL Auditing)';
END
ELSE
BEGIN
    BEGIN TRY
        INSERT INTO #AuditGroups (GroupName)
        SELECT ad.name
        FROM sys.server_audits au
        JOIN sys.server_audit_specifications aspec ON au.audit_guid = aspec.audit_guid
        JOIN sys.server_audit_specification_details ad ON aspec.audit_specification_id = ad.audit_specification_id
        WHERE au.is_state_enabled = 1;

        IF EXISTS (SELECT 1 FROM #AuditGroups WHERE GroupName IN ('PRINCIPAL_CHANGE_GROUP', 'DATABASE_PERMISSION_CHANGE_GROUP', 'SERVER_PERMISSION_CHANGE_GROUP'))
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Active audit found capturing security changes (PRINCIPAL/PERMISSION groups)';
        END
        ELSE IF EXISTS (SELECT 1 FROM #AuditGroups)
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Active audit found, but specific security change groups are not explicitly enabled';
        END
        ELSE
        BEGIN
            -- Check if audits exist but are disabled
            IF EXISTS (SELECT 1 FROM sys.server_audits WHERE is_state_enabled = 0)
            BEGIN
                SET @Score = 1;
                SET @Finding = 'SQL Server Audit is configured but currently disabled';
            END
            ELSE
            BEGIN
                SET @Score = 0;
                SET @Finding = 'No SQL Server Audit configured';
            END
        END
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = 'Error evaluating audits: ' + ERROR_MESSAGE();
    END CATCH
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #AuditGroups;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;