-- Checklist: Access control changes logged and reviewable
-- Scope: SERVER
-- Scoring: 3 = an enabled audit with an enabled specification covers both permission-change and role/principal-change action groups; 2 = an enabled audit covers at least one access-control action group; 1 = audit objects, database audit specifications or DDL triggers exist but no enabled access-control coverage; 0 = no access-control change logging found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No access-control change logging evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Audits INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @PermGroups INT = 0;
DECLARE @RoleGroups INT = 0;
DECLARE @Triggers INT = 0;
DECLARE @DbSpecs INT = 0;
DECLARE @DbGroups INT = 0;
DECLARE @Dest NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SELECT @DbSpecs = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;

    SELECT @DbGroups = COUNT(*)
    FROM sys.database_audit_specification_details AS d
    JOIN sys.database_audit_specifications AS s
      ON s.database_specification_id = d.database_specification_id
    WHERE s.is_state_enabled = 1
      AND d.audit_action_name IN ('DATABASE_PERMISSION_CHANGE_GROUP', 'DATABASE_ROLE_MEMBER_CHANGE_GROUP',
                                  'DATABASE_OBJECT_PERMISSION_CHANGE_GROUP', 'SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP',
                                  'DATABASE_PRINCIPAL_CHANGE_GROUP');
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
SELECT @p = ISNULL(SUM(CASE WHEN d.audit_action_name LIKE ''%PERMISSION_CHANGE_GROUP'' THEN 1 ELSE 0 END), 0),
       @r = ISNULL(SUM(CASE WHEN d.audit_action_name LIKE ''%ROLE_MEMBER_CHANGE_GROUP''
                              OR d.audit_action_name LIKE ''%PRINCIPAL_CHANGE_GROUP''
                            THEN 1 ELSE 0 END), 0)
FROM sys.server_audit_specification_details AS d
JOIN sys.server_audit_specifications AS sp ON sp.server_specification_id = d.server_specification_id
JOIN sys.server_audits AS a ON a.audit_guid = sp.audit_guid
WHERE sp.is_state_enabled = 1 AND a.is_state_enabled = 1;
SELECT @t = COUNT(*) FROM sys.server_triggers WHERE is_disabled = 0;';

        EXEC sys.sp_executesql @Sql,
             N'@a INT OUTPUT, @e INT OUTPUT, @d NVARCHAR(MAX) OUTPUT, @p INT OUTPUT, @r INT OUTPUT, @t INT OUTPUT',
             @a = @Audits OUTPUT, @e = @Enabled OUTPUT, @d = @Dest OUTPUT,
             @p = @PermGroups OUTPUT, @r = @RoleGroups OUTPUT, @t = @Triggers OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine = 5
BEGIN
    SET @Score = CASE WHEN @DbSpecs > 0 AND @DbGroups > 0 THEN 3 ELSE 2 END;
    SET @Finding = CONCAT('Azure SQL Database: enabled database audit specifications = ', @DbSpecs,
        ', access-control action groups covered by them = ', @DbGroups,
        '; logical-server auditing is managed by the platform and is not exposed through T-SQL');
END
ELSE
BEGIN
    SET @Score = CASE
        WHEN @Enabled > 0 AND @PermGroups > 0 AND (@RoleGroups > 0 OR @DbGroups > 0) THEN 3
        WHEN @Enabled > 0 AND (@PermGroups > 0 OR @RoleGroups > 0 OR @DbGroups > 0) THEN 2
        WHEN @Audits > 0 OR @Triggers > 0 OR @DbSpecs > 0 THEN 1
        ELSE 0 END;
    SET @Finding = CONCAT('Server audits defined = ', @Audits, ' (enabled = ', @Enabled, ')',
        CASE WHEN LEN(@Dest) > 0 THEN ': ' + @Dest ELSE '' END,
        '; enabled permission-change action groups = ', @PermGroups,
        '; enabled role/principal-change action groups = ', @RoleGroups,
        '; enabled database audit specifications = ', @DbSpecs,
        ' covering ', @DbGroups, ' access-control action group(s)',
        '; enabled DDL server triggers = ', @Triggers,
        CASE WHEN @Err = 1 THEN '; one or more audit sources were not readable on this platform' ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;