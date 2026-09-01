-- Checklist: Login/permission changes captured and reviewable
-- Scope: SERVER
-- Scoring: 3 = an enabled audit captures both login action groups and permission/role-change action groups; 2 = an enabled audit captures one of the two, or login auditing records both successful and failed logins; 1 = audit objects or partial login auditing exist but no enabled coverage; 0 = neither logins nor permission changes are captured

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No login or permission change capture evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Audits INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @LoginGroups INT = 0;
DECLARE @PermGroups INT = 0;
DECLARE @DbSpecs INT = 0;
DECLARE @AuditLevel INT = NULL;
DECLARE @Dest NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SELECT @DbSpecs = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;
END TRY
BEGIN CATCH
    SET @Err = 1;
END CATCH

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @a = COUNT(*),
       @e = ISNULL(SUM(CASE WHEN is_state_enabled = 1 THEN 1 ELSE 0 END), 0),
       @d = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), name + '' ['' + type_desc + '']''), '', ''), 300), '''')
FROM sys.server_audits;
SELECT @g = ISNULL(SUM(CASE WHEN d.audit_action_name IN (''SUCCESSFUL_LOGIN_GROUP'', ''FAILED_LOGIN_GROUP'',
                                                         ''LOGIN_CHANGE_PASSWORD_GROUP'')
                            THEN 1 ELSE 0 END), 0),
       @p = ISNULL(SUM(CASE WHEN d.audit_action_name LIKE ''%PERMISSION_CHANGE_GROUP''
                              OR d.audit_action_name LIKE ''%ROLE_MEMBER_CHANGE_GROUP''
                              OR d.audit_action_name LIKE ''%PRINCIPAL_CHANGE_GROUP''
                            THEN 1 ELSE 0 END), 0)
FROM sys.server_audit_specification_details AS d
JOIN sys.server_audit_specifications AS sp ON sp.server_specification_id = d.server_specification_id
JOIN sys.server_audits AS a ON a.audit_guid = sp.audit_guid
WHERE sp.is_state_enabled = 1 AND a.is_state_enabled = 1;';

        EXEC sys.sp_executesql @Sql,
             N'@a INT OUTPUT, @e INT OUTPUT, @d NVARCHAR(MAX) OUTPUT, @g INT OUTPUT, @p INT OUTPUT',
             @a = @Audits OUTPUT, @e = @Enabled OUTPUT, @d = @Dest OUTPUT,
             @g = @LoginGroups OUTPUT, @p = @PermGroups OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine <> 5 AND @Engine <> 8
BEGIN
    BEGIN TRY
        SET @Sql = N'EXEC master.dbo.xp_instance_regread N''HKEY_LOCAL_MACHINE'', N''Software\Microsoft\MSSQLServer\MSSQLServer'', N''AuditLevel'', @v OUTPUT;';
        EXEC sys.sp_executesql @Sql, N'@v INT OUTPUT', @v = @AuditLevel OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine = 5
BEGIN
    SET @Score = CASE WHEN @DbSpecs > 0 THEN 3 ELSE 2 END;
    SET @Finding = CONCAT('Azure SQL Database: enabled database audit specifications = ', @DbSpecs,
        '; login and permission-change auditing is configured on the logical server and is not exposed through T-SQL');
END
ELSE
BEGIN
    SET @Score = CASE
        WHEN @Enabled > 0 AND @LoginGroups > 0 AND @PermGroups > 0 THEN 3
        WHEN @Enabled > 0 AND (@LoginGroups > 0 OR @PermGroups > 0) THEN 2
        WHEN ISNULL(@AuditLevel, 0) = 3 THEN 2
        WHEN @Audits > 0 OR @DbSpecs > 0 OR ISNULL(@AuditLevel, 0) > 0 THEN 1
        ELSE 0 END;
    SET @Finding = CONCAT('Server audits defined = ', @Audits, ' (enabled = ', @Enabled, ')',
        CASE WHEN LEN(@Dest) > 0 THEN ': ' + @Dest ELSE '' END,
        '; enabled login action groups = ', @LoginGroups,
        '; enabled permission/role/principal-change action groups = ', @PermGroups,
        '; enabled database audit specifications = ', @DbSpecs,
        '; login auditing registry AuditLevel = ',
        CASE WHEN @AuditLevel IS NULL THEN 'not readable' ELSE CONVERT(NVARCHAR(10), @AuditLevel) END,
        CASE WHEN @Err = 1 THEN '; one or more sources were not readable on this platform' ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;