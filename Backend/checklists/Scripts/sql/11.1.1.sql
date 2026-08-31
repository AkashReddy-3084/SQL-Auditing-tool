-- Checklist: Database schema and code source-controlled (SSDT/SQL project or migration scripts)
-- Scope: DATABASE
-- Scoring: 3 = a recognized migration-tracking table (EF Migrations, Flyway, DbUp, etc.) is found; 2 = reserved; 1 = reserved; 0 = no migration-tracking table found
-- NOTE: Automated evidence only; this detects a migration-framework artifact, not the actual source-control repository. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @MigrationTableCount INT;

    SELECT @MigrationTableCount = COUNT(*) FROM sys.tables
    WHERE name IN ('__EFMigrationsHistory','flyway_schema_history','SchemaVersions','__MigrationHistory','DbUp','dbo.__MigrationHistory')
       OR name LIKE '%migration%history%' OR name LIKE '%schema_version%';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@MigrationTableCount,0) > 0 THEN 3 ELSE 0 END,
        CASE WHEN ISNULL(@MigrationTableCount,0) > 0 THEN CONCAT('Schema-migration tracking tables found = ', @MigrationTableCount)
             ELSE 'No recognized schema-migration tracking table found' END
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @mc INT;
SELECT @mc = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables
WHERE name IN (''__EFMigrationsHistory'',''flyway_schema_history'',''SchemaVersions'',''__MigrationHistory'',''DbUp'')
   OR name LIKE ''%migration%history%'' OR name LIKE ''%schema_version%'';
SELECT @p_Db,
       CASE WHEN ISNULL(@mc,0) > 0 THEN 3 ELSE 0 END,
       CASE WHEN ISNULL(@mc,0) > 0 THEN CONCAT(''Schema-migration tracking tables found = '', @mc)
            ELSE ''No recognized schema-migration tracking table found'' END;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;