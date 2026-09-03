-- Checklist: Database schema and code source-controlled (SSDT/SQL project or migration scripts)
-- Scope: DATABASE
-- Scoring: 3 = a migration/version tracking artefact exists and holds recorded versions; 2 = the artefact exists but is empty; 1 = only SSDT/DAC tooling metadata found; 0 = no source-control artefact found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Source-control artefacts could not be inspected in this database';

DECLARE @Artefacts TABLE
(
    FullName NVARCHAR(300) NOT NULL,
    RowsHeld BIGINT        NOT NULL
);

DECLARE @ArtefactCount INT = 0;
DECLARE @PopulatedCount INT = 0;
DECLARE @SsdtProps INT = 0;
DECLARE @List NVARCHAR(MAX) = '';

BEGIN TRY
    INSERT INTO @Artefacts (FullName, RowsHeld)
    SELECT s.name + '.' + t.name, ISNULL(rc.RowCnt, 0)
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    OUTER APPLY (SELECT SUM(ps.row_count) AS RowCnt
                 FROM sys.dm_db_partition_stats AS ps
                 WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) AS rc
    WHERE t.name IN ('__EFMigrationsHistory', '__MigrationHistory', '__RefactorLog',
                     'flyway_schema_history', 'schema_version', 'SchemaVersions',
                     'VersionInfo', 'ScriptsRun', 'DatabaseVersion', 'DATABASECHANGELOG')
       OR t.name LIKE '%MigrationHistory%'
       OR t.name LIKE '%SchemaVersion%'
       OR t.name LIKE '%schema[_]history%';
END TRY
BEGIN CATCH
    SET @Score = 0;
END CATCH

BEGIN TRY
    SELECT @SsdtProps = COUNT(*)
    FROM sys.extended_properties
    WHERE name IN ('microsoft_database_tools_support', 'DacVersion', 'DacPackageName', 'BlueprintVersion');
END TRY
BEGIN CATCH
    SET @SsdtProps = 0;
END CATCH

SELECT @ArtefactCount = COUNT(*),
       @PopulatedCount = ISNULL(SUM(CASE WHEN RowsHeld > 0 THEN 1 ELSE 0 END), 0)
FROM @Artefacts;

SET @List = ISNULL((SELECT LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), ', '), 400) FROM @Artefacts), '');

SET @Score = CASE WHEN @PopulatedCount > 0 THEN 3
                  WHEN @ArtefactCount > 0 THEN 2
                  WHEN @SsdtProps > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @ArtefactCount = 0 AND @SsdtProps = 0
        THEN 'No migration-history, version-tracking or SSDT refactor-log table exists and no database-tooling extended property is present, so no in-database evidence of source-controlled schema and code was found'
    WHEN @ArtefactCount = 0
        THEN CONCAT('No migration or version-tracking table found; only ', @SsdtProps,
                    ' SSDT/DAC tooling extended propert(ies) are present')
    ELSE CONCAT(@ArtefactCount, ' source-control artefact table(s) found (', @List, '); ',
                @PopulatedCount, ' of them hold recorded versions; SSDT/DAC tooling properties = ', @SsdtProps)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
