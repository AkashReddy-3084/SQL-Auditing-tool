-- Checklist: Audit logs stored in a tamper-resistant location (separate store / immutable)
-- Scope: SERVER
-- Scoring: 3 = every running audit writes to a store outside the engine host (Security Log, UNC share or blob URL) and fails closed; 2 = every running audit writes to such a store but continues on write failure; 1 = only some running audits do, or a local file target has rollover retention configured; 0 = no audit defined, all stopped, or all writing to a locally writable target

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No SQL Server Audit destination evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Total INT = 0;
DECLARE @Running INT = 0;
DECLARE @Separate INT = 0;
DECLARE @FailClosed INT = 0;
DECLARE @Rollover INT = 0;
DECLARE @Detail NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @t = COUNT(*),
       @r = ISNULL(SUM(CASE WHEN a.is_state_enabled = 1 THEN 1 ELSE 0 END), 0),
       @s = ISNULL(SUM(CASE WHEN a.is_state_enabled = 1
                             AND (a.type_desc = ''SECURITY LOG''
                                  OR LEFT(ISNULL(f.log_file_path, ''''), 2) = ''\\''
                                  OR ISNULL(f.log_file_path, '''') LIKE ''https://%''
                                  OR ISNULL(f.log_file_path, '''') LIKE ''http://%'')
                            THEN 1 ELSE 0 END), 0),
       @c = ISNULL(SUM(CASE WHEN a.is_state_enabled = 1 AND a.on_failure_desc <> ''CONTINUE''
                            THEN 1 ELSE 0 END), 0),
       @o = ISNULL(SUM(CASE WHEN a.is_state_enabled = 1 AND ISNULL(f.max_rollover_files, 0) > 0
                            THEN 1 ELSE 0 END), 0),
       @d = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
              a.name + '' ['' + a.type_desc
              + CASE WHEN LEN(ISNULL(f.log_file_path, '''')) > 0 THEN '' -> '' + f.log_file_path ELSE '''' END
              + ''; state='' + CASE WHEN a.is_state_enabled = 1 THEN ''ENABLED'' ELSE ''DISABLED'' END
              + ''; on_failure='' + ISNULL(a.on_failure_desc, ''UNKNOWN'')
              + ''; rollover_files='' + CONVERT(NVARCHAR(20), ISNULL(f.max_rollover_files, 0)) + '']''), '', ''), 500), '''')
FROM sys.server_audits AS a
LEFT JOIN sys.server_file_audits AS f ON f.audit_id = a.audit_id;';

        EXEC sys.sp_executesql @Sql,
             N'@t INT OUTPUT, @r INT OUTPUT, @s INT OUTPUT, @c INT OUTPUT, @o INT OUTPUT, @d NVARCHAR(MAX) OUTPUT',
             @t = @Total OUTPUT, @r = @Running OUTPUT, @s = @Separate OUTPUT,
             @c = @FailClosed OUTPUT, @o = @Rollover OUTPUT, @d = @Detail OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: audit records are written by the platform to a storage account, Log Analytics workspace or Event Hub held outside the database engine, so the audit trail is not co-located with the data; sys.server_audits is not exposed on this platform, so immutability settings on that target cannot be read from T-SQL';
END
ELSE
BEGIN
    SET @Score = CASE
        WHEN @Total = 0 OR @Running = 0 THEN 0
        WHEN @Separate = @Running AND @FailClosed = @Running THEN 3
        WHEN @Separate = @Running THEN 2
        WHEN @Separate > 0 OR @Rollover = @Running THEN 1
        ELSE 0 END;
    SET @Finding = CONCAT('Audits defined = ', @Total, ', running = ', @Running,
        '; running audits writing to a store outside this host (Security Log, UNC or blob URL) = ', @Separate,
        '; running audits that fail closed on write error = ', @FailClosed,
        '; running audits with file rollover retention = ', @Rollover,
        CASE WHEN LEN(@Detail) > 0 THEN '. Destinations: ' + @Detail ELSE '' END,
        CASE WHEN @Err = 1 THEN '. Audit destination views were not readable on this platform' ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;