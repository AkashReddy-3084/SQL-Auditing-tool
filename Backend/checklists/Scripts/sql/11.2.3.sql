-- Checklist: Schema drift detected and reconciled between environments
-- Scope: DATABASE
-- Scoring: 3 = an enabled database DDL trigger and a populated schema-change/migration log are both present; 2 = one of them is actively recording changes; 1 = a drift-detection artefact exists but records nothing; 0 = no drift detection artefact in this database

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Schema-drift controls could not be inspected in this database';

DECLARE @Logs TABLE
(
    FullName NVARCHAR(300) NOT NULL,
    RowsHeld BIGINT        NOT NULL
);

DECLARE @DdlTriggers INT = 0;
DECLARE @TriggerList NVARCHAR(MAX) = '';
DECLARE @LogTables INT = 0;
DECLARE @PopulatedLogs INT = 0;
DECLARE @LogList NVARCHAR(MAX) = '';
DECLARE @ChangedObjects INT = 0;
DECLARE @TotalObjects INT = 0;

BEGIN TRY
    SELECT @DdlTriggers = COUNT(*),
           @TriggerList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), name), ', '), 300), '')
    FROM sys.triggers
    WHERE parent_class = 0 AND is_disabled = 0;
END TRY
BEGIN CATCH
    SET @DdlTriggers = 0;
END CATCH

BEGIN TRY
    INSERT INTO @Logs (FullName, RowsHeld)
    SELECT s.name + '.' + t.name, ISNULL(rc.RowCnt, 0)
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    OUTER APPLY (SELECT SUM(ps.row_count) AS RowCnt
                 FROM sys.dm_db_partition_stats AS ps
                 WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) AS rc
    WHERE t.name LIKE '%schemachange%' OR t.name LIKE '%schema[_]change%'
       OR t.name LIKE '%ddllog%' OR t.name LIKE '%ddl[_]log%' OR t.name LIKE '%ddl[_]event%'
       OR t.name LIKE '%drift%' OR t.name LIKE '%MigrationHistory%' OR t.name LIKE '%SchemaVersion%'
       OR t.name IN ('__EFMigrationsHistory', 'flyway_schema_history', 'SchemaVersions',
                     'VersionInfo', 'ScriptsRun', 'DATABASECHANGELOG');
END TRY
BEGIN CATCH
    SET @Score = 0;
END CATCH

SELECT @LogTables = COUNT(*),
       @PopulatedLogs = ISNULL(SUM(CASE WHEN RowsHeld > 0 THEN 1 ELSE 0 END), 0),
       @LogList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), ', '), 300), '')
FROM @Logs;

BEGIN TRY
    SELECT @TotalObjects = COUNT(*),
           @ChangedObjects = ISNULL(SUM(CASE WHEN modify_date > create_date THEN 1 ELSE 0 END), 0)
    FROM sys.objects
    WHERE is_ms_shipped = 0 AND type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'TR');
END TRY
BEGIN CATCH
    SET @TotalObjects = 0;
END CATCH

SET @Score = CASE WHEN @DdlTriggers > 0 AND @PopulatedLogs > 0 THEN 3
                  WHEN @DdlTriggers > 0 OR @PopulatedLogs > 0 THEN 2
                  WHEN @LogTables > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CONCAT('Enabled database DDL triggers = ', @DdlTriggers,
                      CASE WHEN @DdlTriggers > 0 THEN CONCAT(' (', @TriggerList, ')') ELSE '' END,
                      '; schema-change/migration log tables = ', @LogTables,
                      CASE WHEN @LogTables > 0
                           THEN CONCAT(' (', @LogList, '), of which ', @PopulatedLogs, ' hold recorded changes')
                           ELSE '' END,
                      '; ', @ChangedObjects, ' of ', @TotalObjects,
                      ' user objects have been changed since they were first created');

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
