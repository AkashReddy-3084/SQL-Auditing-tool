-- Checklist: No manual production changes - all via pipeline
-- Scope: SERVER
-- Scoring: 3 = DDL-change auditing or an enabled server DDL trigger is active and no interactive ad-hoc tool sessions are connected; 2 = that change capture is active but interactive tool sessions are connected; 1 = no DDL auditing, only the default trace captures object changes; 0 = no DDL change capture of any kind

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No change-control evidence could be read from this instance';

DECLARE @AuditActions INT = 0;
DECLARE @DdlTriggers INT = 0;
DECLARE @DefaultTrace INT = 0;
DECLARE @AdHocSessions INT = 0;
DECLARE @AdHocList NVARCHAR(MAX) = '';
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    IF OBJECT_ID('sys.server_audit_specification_details') IS NOT NULL
    BEGIN
        SET @Sql = N'SELECT @n = COUNT(*) FROM sys.server_audit_specification_details
WHERE audit_action_name IN (N''SCHEMA_OBJECT_CHANGE_GROUP'', N''DATABASE_OBJECT_CHANGE_GROUP'',
                            N''SERVER_OBJECT_CHANGE_GROUP'', N''DATABASE_CHANGE_GROUP'');';
        EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @AuditActions OUTPUT;
    END
    ELSE IF OBJECT_ID('sys.database_audit_specification_details') IS NOT NULL
    BEGIN
        SET @Sql = N'SELECT @n = COUNT(*) FROM sys.database_audit_specification_details
WHERE audit_action_name IN (N''SCHEMA_OBJECT_CHANGE_GROUP'', N''DATABASE_OBJECT_CHANGE_GROUP'');';
        EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @AuditActions OUTPUT;
    END
END TRY
BEGIN CATCH
    SET @AuditActions = 0;
END CATCH

BEGIN TRY
    IF OBJECT_ID('sys.server_triggers') IS NOT NULL
    BEGIN
        SET @Sql = N'SELECT @n = COUNT(*) FROM sys.server_triggers WHERE is_disabled = 0;';
        EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @DdlTriggers OUTPUT;
    END
END TRY
BEGIN CATCH
    SET @DdlTriggers = 0;
END CATCH

BEGIN TRY
    SELECT @DefaultTrace = ISNULL(MAX(CONVERT(INT, value_in_use)), 0)
    FROM sys.configurations
    WHERE name = 'default trace enabled';
END TRY
BEGIN CATCH
    SET @DefaultTrace = 0;
END CATCH

BEGIN TRY
    SELECT @AdHocSessions = COUNT(*),
           @AdHocList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), program_name), ', '), 300), '')
    FROM sys.dm_exec_sessions
    WHERE is_user_process = 1
      AND (program_name LIKE '%Management Studio%'
           OR program_name LIKE '%Azure Data Studio%'
           OR program_name LIKE '%SQLCMD%'
           OR program_name LIKE '%LINQPad%');
END TRY
BEGIN CATCH
    SET @AdHocSessions = 0;
END CATCH

SET @AuditActions = ISNULL(@AuditActions, 0);
SET @DdlTriggers = ISNULL(@DdlTriggers, 0);

SET @Score = CASE
    WHEN (@AuditActions > 0 OR @DdlTriggers > 0) AND @AdHocSessions = 0 THEN 3
    WHEN @AuditActions > 0 OR @DdlTriggers > 0 THEN 2
    WHEN @DefaultTrace = 1 THEN 1
    ELSE 0 END;

SET @Finding = CONCAT('Object-change audit action groups configured = ', @AuditActions,
                      '; enabled server DDL triggers = ', @DdlTriggers,
                      '; default trace enabled = ', @DefaultTrace,
                      '; interactive ad-hoc tool sessions currently connected = ', @AdHocSessions,
                      CASE WHEN @AdHocSessions > 0 THEN CONCAT(' (', @AdHocList, ')') ELSE '' END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
