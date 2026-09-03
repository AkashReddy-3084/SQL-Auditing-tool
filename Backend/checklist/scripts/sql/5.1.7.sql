-- Checklist: DQ failures halt progression where critical (bad data not silently promoted)
-- Scope: DATABASE
-- Scoring: 3 = halting validation modules and reject/quarantine tables both present; 2 = halting validation modules present; 1 = only reject/quarantine tables present; 0 = no DQ gating evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'DQ gating evidence could not be collected in the current database';
DECLARE @RaisePattern NVARCHAR(60) = '%' + CHAR(82) + 'AISERROR%';
DECLARE @ThrowPattern NVARCHAR(60) = '%' + CHAR(84) + 'HROW%';
DECLARE @RollbackPattern NVARCHAR(60) = '%' + CHAR(82) + 'OLLBACK%';
DECLARE @Modules INT = 0;
DECLARE @HaltModules INT = 0;
DECLARE @GateTables INT = 0;
DECLARE @ModuleList NVARCHAR(MAX) = '';
DECLARE @TableList NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;

BEGIN TRY
    SELECT @Modules = COUNT(*) FROM sys.sql_modules;

    SELECT @HaltModules = COUNT(*),
           @ModuleList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + o.name), ', '), 300), '')
    FROM sys.sql_modules AS m
    JOIN sys.objects AS o ON o.object_id = m.object_id
    JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND (m.definition LIKE @RaisePattern
           OR m.definition LIKE @ThrowPattern
           OR m.definition LIKE @RollbackPattern)
      AND (o.name LIKE '%valid%' OR o.name LIKE '%quality%' OR o.name LIKE '%dq[_]%'
           OR o.name LIKE '%reject%' OR o.name LIKE '%quarantin%' OR o.name LIKE '%check%'
           OR m.definition LIKE '%validat%' OR m.definition LIKE '%data quality%');

    SELECT @GateTables = COUNT(*),
           @TableList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name), ', '), 300), '')
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE '%reject%' OR t.name LIKE '%quarantin%' OR t.name LIKE '%exception%'
           OR t.name LIKE '%[_]error%' OR t.name LIKE 'error%' OR t.name LIKE '%invalid%'
           OR t.name LIKE '%dq[_]%' OR t.name LIKE '%failed%' OR t.name LIKE '%bad[_]%');
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'DQ gating metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SET @Modules = ISNULL(@Modules, 0);
SET @HaltModules = ISNULL(@HaltModules, 0);
SET @GateTables = ISNULL(@GateTables, 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @HaltModules > 0 AND @GateTables > 0 THEN 3
        WHEN @HaltModules > 0 THEN 2
        WHEN @GateTables > 0 THEN 1
        ELSE 0 END;

    IF @Modules = 0 AND @GateTables = 0
        SET @Finding = 'No programmable modules and no reject/quarantine tables found in ' + @DatabaseQueried
                     + '; nothing prevents failed rows from being promoted';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @HaltModules, ' of ', @Modules,
            ' module(s) both validate and abort',
            CASE WHEN LEN(@ModuleList) > 0 THEN ' (' + @ModuleList + ')' ELSE '' END,
            '; ', @GateTables, ' reject/quarantine table(s)',
            CASE WHEN LEN(@TableList) > 0 THEN ' (' + @TableList + ')' ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
