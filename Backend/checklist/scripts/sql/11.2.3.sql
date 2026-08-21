/* Checklist 11.2.3 - Schema drift detected and reconciled between environments. Read-only. */
SET NOCOUNT ON;

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried nvarchar(258) = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN DB_NAME() ELSE N'ALL_USER_DATABASES' END;

IF OBJECT_ID(N'tempdb..#DbSchema') IS NOT NULL DROP TABLE #DbSchema;
CREATE TABLE #DbSchema
(
    DbName          sysname NOT NULL,
    SchemaHash      int     NULL,
    ObjectCount     int     NOT NULL DEFAULT (0),
    MigrationTables int     NOT NULL DEFAULT (0),
    DdlTriggers     int     NOT NULL DEFAULT (0),
    Inspected       bit     NOT NULL DEFAULT (0)
);

IF OBJECT_ID(N'tempdb..#DbBase') IS NOT NULL DROP TABLE #DbBase;
CREATE TABLE #DbBase
(
    DbName     sysname        NOT NULL,
    BaseName   nvarchar(128)  NOT NULL,
    SchemaHash int            NULL
);

IF OBJECT_ID(N'tempdb..#EnvGroups') IS NOT NULL DROP TABLE #EnvGroups;
CREATE TABLE #EnvGroups
(
    BaseName  nvarchar(128)  NOT NULL,
    DbCount   int            NOT NULL,
    HashCount int            NOT NULL,
    DbList    nvarchar(max)  NULL
);

DECLARE @Suffixes TABLE (sfx nvarchar(20) NOT NULL);
INSERT INTO @Suffixes (sfx)
VALUES (N'_DEV'), (N'_DEVELOPMENT'), (N'_TEST'), (N'_TST'), (N'_QA'), (N'_UAT'), (N'_SIT'),
       (N'_STG'), (N'_STAGE'), (N'_STAGING'), (N'_PREPROD'), (N'_PROD'), (N'_PRD'),
       (N'_LIVE'), (N'_DEMO'), (N'_TRAIN');

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #DbSchema (DbName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbSchema (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @Db sysname, @Sql nvarchar(max);
DECLARE @Hash int, @Obj int, @Mig int, @Ddl int;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #DbSchema ORDER BY DbName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Hash = NULL;
    SET @Obj  = 0;
    SET @Mig  = 0;
    SET @Ddl  = 0;

    BEGIN TRY
        SET @Sql = N'
SELECT @hash_out = CHECKSUM_AGG(BINARY_CHECKSUM(
            s.name, o.name, o.type,
            ISNULL(c.name, N''''), ISNULL(c.column_id, 0), ISNULL(c.system_type_id, 0),
            ISNULL(c.max_length, 0), ISNULL(CONVERT(int, c.precision), 0),
            ISNULL(CONVERT(int, c.scale), 0), ISNULL(CONVERT(int, c.is_nullable), 0))),
       @obj_out = COUNT(DISTINCT o.object_id)
FROM ' + QUOTENAME(@Db) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
LEFT JOIN ' + QUOTENAME(@Db) + N'.sys.columns AS c ON c.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'', ''TR'');

SELECT @mig_out = COUNT(*)
FROM ' + QUOTENAME(@Db) + N'.sys.tables AS t
WHERE t.name IN (N''__EFMigrationsHistory'', N''__MigrationHistory'', N''flyway_schema_history'',
                 N''schema_version'', N''SchemaVersions'', N''VersionInfo'', N''ScriptsRun'',
                 N''DatabaseVersion'', N''SchemaChangeLog'', N''DDLEventLog'')
   OR t.name LIKE N''%MigrationHistory%''
   OR t.name LIKE N''%SchemaVersion%''
   OR t.name LIKE N''%schema[_]history%''
   OR t.name LIKE N''%SchemaChange%'';

SELECT @ddl_out = COUNT(*)
FROM ' + QUOTENAME(@Db) + N'.sys.triggers AS tr
WHERE tr.parent_class = 0
  AND tr.is_disabled = 0;';

        EXEC sys.sp_executesql
             @Sql,
             N'@hash_out int OUTPUT, @obj_out int OUTPUT, @mig_out int OUTPUT, @ddl_out int OUTPUT',
             @hash_out = @Hash OUTPUT,
             @obj_out  = @Obj  OUTPUT,
             @mig_out  = @Mig  OUTPUT,
             @ddl_out  = @Ddl  OUTPUT;

        UPDATE #DbSchema
        SET SchemaHash      = @Hash,
            ObjectCount     = ISNULL(@Obj, 0),
            MigrationTables = ISNULL(@Mig, 0),
            DdlTriggers     = ISNULL(@Ddl, 0),
            Inspected       = 1
        WHERE DbName = @Db;
    END TRY
    BEGIN CATCH
        UPDATE #DbSchema
        SET Inspected = 0
        WHERE DbName = @Db;
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

INSERT INTO #DbBase (DbName, BaseName, SchemaHash)
SELECT d.DbName,
       UPPER(CASE WHEN x.sfx IS NULL THEN d.DbName
                  ELSE LEFT(d.DbName, LEN(d.DbName) - LEN(x.sfx)) END),
       d.SchemaHash
FROM #DbSchema AS d
OUTER APPLY
(
    SELECT TOP (1) s.sfx
    FROM @Suffixes AS s
    WHERE LEN(d.DbName) > LEN(s.sfx)
      AND RIGHT(d.DbName, LEN(s.sfx)) = s.sfx
    ORDER BY LEN(s.sfx) DESC
) AS x
WHERE d.Inspected = 1;

INSERT INTO #EnvGroups (BaseName, DbCount, HashCount, DbList)
SELECT g.BaseName,
       COUNT(*),
       COUNT(DISTINCT ISNULL(g.SchemaHash, 0)),
       STUFF((SELECT N', ' + b.DbName
              FROM #DbBase AS b
              WHERE b.BaseName = g.BaseName
              ORDER BY b.DbName
              FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
FROM #DbBase AS g
GROUP BY g.BaseName
HAVING COUNT(*) > 1;

DECLARE @TotalDbs int, @InspectedDbs int, @TrackedDbs int, @PairedGroups int, @DriftGroups int;

SELECT @TotalDbs     = COUNT(*),
       @InspectedDbs = SUM(CASE WHEN Inspected = 1 THEN 1 ELSE 0 END),
       @TrackedDbs   = SUM(CASE WHEN Inspected = 1 AND (MigrationTables > 0 OR DdlTriggers > 0) THEN 1 ELSE 0 END)
FROM #DbSchema;

SELECT @PairedGroups = COUNT(*),
       @DriftGroups  = SUM(CASE WHEN HashCount > 1 THEN 1 ELSE 0 END)
FROM #EnvGroups;

SET @TotalDbs     = ISNULL(@TotalDbs, 0);
SET @InspectedDbs = ISNULL(@InspectedDbs, 0);
SET @TrackedDbs   = ISNULL(@TrackedDbs, 0);
SET @PairedGroups = ISNULL(@PairedGroups, 0);
SET @DriftGroups  = ISNULL(@DriftGroups, 0);

DECLARE @UntrackedList nvarchar(max), @DriftList nvarchar(max);

SET @UntrackedList = STUFF((SELECT N', ' + d.DbName
                            FROM #DbSchema AS d
                            WHERE d.Inspected = 1
                              AND d.MigrationTables = 0
                              AND d.DdlTriggers = 0
                            ORDER BY d.DbName
                            FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @DriftList = STUFF((SELECT N'; ' + g.BaseName + N' (' + ISNULL(g.DbList, N'') + N')'
                        FROM #EnvGroups AS g
                        WHERE g.HashCount > 1
                        ORDER BY g.BaseName
                        FOR XML PATH(N''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Score int, @Result nvarchar(20), @Finding nvarchar(4000);

IF @InspectedDbs = 0
    SET @Score = 1;
ELSE IF @TrackedDbs = @InspectedDbs AND @DriftGroups = 0
    SET @Score = 3;
ELSE IF @TrackedDbs > 0
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Inspected ' + CONVERT(nvarchar(10), @InspectedDbs) + N' of ' + CONVERT(nvarchar(10), @TotalDbs)
    + N' accessible user database(s). Schema-change tracking evidence (migration/schema-version history table or enabled database DDL trigger) found in '
    + CONVERT(nvarchar(10), @TrackedDbs) + N' database(s). Environment-paired database group(s) detected: '
    + CONVERT(nvarchar(10), @PairedGroups) + N', of which ' + CONVERT(nvarchar(10), @DriftGroups)
    + N' show differing schema checksums (unreconciled drift).'
    + CASE WHEN @UntrackedList IS NULL THEN N''
           ELSE N' Databases without tracking evidence: ' + LEFT(@UntrackedList, 1200) + N'.' END
    + CASE WHEN @DriftList IS NULL THEN N''
           ELSE N' Drifting group(s): ' + LEFT(@DriftList, 1200) + N'.' END
    + CASE WHEN @PairedGroups = 0
           THEN N' No environment-suffixed database copies exist on this instance, so cross-environment comparison was assessed from schema-change tracking evidence only; confirm drift reconciliation against the other environment servers.'
           ELSE N'' END;

SELECT @Result              AS Result,
       @Score               AS Score,
       @DatabaseQueried     AS DatabaseQueried,
       LEFT(@Finding, 4000) AS Finding;