-- Checklist: Data access to sensitive tables auditable (who accessed what, when)
-- Scope: SERVER
-- Scoring: 3 = an enabled audit covers object access / SELECT actions and sensitive columns are classified; 2 = an enabled audit covers object access / SELECT actions, or the platform hosts auditing outside the engine; 1 = audits or classifications exist but read access is not covered; 0 = no read-access auditing and no classification

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No read-access auditing or data classification evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Audits INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @ObjAccess INT = 0;
DECLARE @DbSpecs INT = 0;
DECLARE @SelectActions INT = 0;
DECLARE @Classified INT = 0;
DECLARE @Dest NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SELECT @DbSpecs = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;

    SELECT @SelectActions = COUNT(*)
    FROM sys.database_audit_specification_details AS d
    JOIN sys.database_audit_specifications AS s
      ON s.database_specification_id = d.database_specification_id
    WHERE s.is_state_enabled = 1
      AND (d.audit_action_name = 'SELECT' OR d.audit_action_name LIKE '%OBJECT_ACCESS_GROUP');
END TRY
BEGIN CATCH
    SET @Err = 1;
END CATCH

IF OBJECT_ID('sys.sensitivity_classifications') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*) FROM sys.sensitivity_classifications;';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @Classified OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @a = COUNT(*),
       @e = ISNULL(SUM(CASE WHEN is_state_enabled = 1 THEN 1 ELSE 0 END), 0),
       @d = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), name + '' ['' + type_desc + '']''), '', ''), 300), '''')
FROM sys.server_audits;
SELECT @o = ISNULL(SUM(CASE WHEN d.audit_action_name LIKE ''%OBJECT_ACCESS_GROUP'' THEN 1 ELSE 0 END), 0)
FROM sys.server_audit_specification_details AS d
JOIN sys.server_audit_specifications AS sp ON sp.server_specification_id = d.server_specification_id
JOIN sys.server_audits AS a ON a.audit_guid = sp.audit_guid
WHERE sp.is_state_enabled = 1 AND a.is_state_enabled = 1;';

        EXEC sys.sp_executesql @Sql,
             N'@a INT OUTPUT, @e INT OUTPUT, @d NVARCHAR(MAX) OUTPUT, @o INT OUTPUT',
             @a = @Audits OUTPUT, @e = @Enabled OUTPUT, @d = @Dest OUTPUT, @o = @ObjAccess OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

SET @Score = CASE
    WHEN (@Enabled > 0 OR @Engine = 5) AND (@ObjAccess > 0 OR @SelectActions > 0) AND @Classified > 0 THEN 3
    WHEN (@Enabled > 0 OR @Engine = 5) AND (@ObjAccess > 0 OR @SelectActions > 0) THEN 2
    WHEN @Engine = 5 AND @DbSpecs = 0 THEN 2
    WHEN @Audits > 0 OR @DbSpecs > 0 OR @Classified > 0 THEN 1
    ELSE 0 END;

SET @Finding = CONCAT(
    CASE WHEN @Engine = 5 THEN 'Azure SQL Database: ' ELSE '' END,
    'server audits defined = ', @Audits, ' (enabled = ', @Enabled, ')',
    CASE WHEN LEN(@Dest) > 0 THEN ': ' + @Dest ELSE '' END,
    '; enabled server object-access action groups = ', @ObjAccess,
    '; enabled database audit specifications = ', @DbSpecs,
    ' covering ', @SelectActions, ' SELECT/object-access action(s)',
    '; classified sensitive columns = ', @Classified,
    CASE WHEN @Engine = 5 AND @DbSpecs = 0
         THEN '; auditing may be configured on the logical server, which is not exposed through T-SQL' ELSE '' END,
    CASE WHEN @Err = 1 THEN '; one or more sources were not readable on this platform' ELSE '' END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
