/* Checklist 2.1.5 - Reusable/templated ETL components (no copy-paste per table)
   Read-only proxy audit of ETL code artifacts: templated procedures, metadata-driven
   dynamic SQL, ETL control/config tables, SSIS catalog parameterisation, and
   copy-paste-per-table naming families. */
SET NOCOUNT ON;

DECLARE @EngineEdition       INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb        BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (5, 6, 11) THEN 1 ELSE 0 END;
DECLARE @db                  SYSNAME;
DECLARE @sql                 NVARCHAR(MAX);
DECLARE @DbCount             INT = 0;
DECLARE @TotalEtlProcs       INT = 0;
DECLARE @ReusableProcs       INT = 0;
DECLARE @ConfigTables        INT = 0;
DECLARE @CopyPasteFamilies   INT = 0;
DECLARE @CopyPasteProcs      INT = 0;
DECLARE @SsisProjects        INT = 0;
DECLARE @SsisPackages        INT = 0;
DECLARE @SsisParamPackages   INT = 0;
DECLARE @LegacyPackages      INT = 0;
DECLARE @ReuseSignals        INT = 0;
DECLARE @TopFamily           NVARCHAR(500) = NULL;
DECLARE @DbList              NVARCHAR(MAX) = NULL;
DECLARE @DatabaseQueried     NVARCHAR(500);
DECLARE @Result              NVARCHAR(50);
DECLARE @Score               INT;
DECLARE @Verdict             NVARCHAR(1000);
DECLARE @Finding             NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#Db')  IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Etl') IS NOT NULL DROP TABLE #Etl;
IF OBJECT_ID('tempdb..#Cfg') IS NOT NULL DROP TABLE #Cfg;

CREATE TABLE #Db (DbName SYSNAME NOT NULL PRIMARY KEY);

CREATE TABLE #Etl
(
    DbName             SYSNAME       NOT NULL,
    SchemaName         SYSNAME       NOT NULL,
    ProcName           SYSNAME       NOT NULL,
    ParamCount         INT           NOT NULL,
    HasTemplateParam   BIT           NOT NULL,
    HasDynamicMetadata BIT           NOT NULL,
    FamilyKey          NVARCHAR(300) NOT NULL
);

CREATE TABLE #Cfg (DbName SYSNAME NOT NULL, ConfigObjects INT NOT NULL);

/* ---- 1. Database inventory ------------------------------------------------ */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Db (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Db (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1
      AND d.name NOT IN ('SSISDB', 'ReportServer', 'ReportServerTempDB', 'distribution');
END

SELECT @DbCount = COUNT(*) FROM #Db;

/* ---- 2. ETL procedure and config-table inventory per database ------------- */
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #Db ORDER BY DbName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
        INSERT INTO #Etl (DbName, SchemaName, ProcName, ParamCount, HasTemplateParam, HasDynamicMetadata, FamilyKey)
        SELECT ' + QUOTENAME(@db, '''') + N',
               s.name,
               p.name,
               (SELECT COUNT(*) FROM ' + QUOTENAME(@db) + N'.sys.parameters AS pc WHERE pc.object_id = p.object_id),
               CASE WHEN EXISTS (SELECT 1
                                 FROM ' + QUOTENAME(@db) + N'.sys.parameters AS pt
                                 WHERE pt.object_id = p.object_id
                                   AND (pt.name LIKE ''%table%''   OR pt.name LIKE ''%entity%''
                                     OR pt.name LIKE ''%object%''  OR pt.name LIKE ''%source%''
                                     OR pt.name LIKE ''%target%''  OR pt.name LIKE ''%schema%''
                                     OR pt.name LIKE ''%dataset%'' OR pt.name LIKE ''%feed%''
                                     OR pt.name LIKE ''%stream%''))
                    THEN 1 ELSE 0 END,
               CASE WHEN ISNULL(m.definition, N'''') LIKE ''%sp[_]executesql%''
                     AND (ISNULL(m.definition, N'''') LIKE ''%sys.tables%''
                       OR ISNULL(m.definition, N'''') LIKE ''%sys.columns%''
                       OR ISNULL(m.definition, N'''') LIKE ''%sys.objects%''
                       OR ISNULL(m.definition, N'''') LIKE ''%INFORMATION[_]SCHEMA%''
                       OR ISNULL(m.definition, N'''') LIKE ''%QUOTENAME%'')
                    THEN 1 ELSE 0 END,
               CASE WHEN CHARINDEX(''_'', REVERSE(p.name)) > 0
                    THEN LEFT(p.name, LEN(p.name) - CHARINDEX(''_'', REVERSE(p.name)))
                    ELSE p.name END
        FROM ' + QUOTENAME(@db) + N'.sys.procedures AS p
        INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = p.schema_id
        LEFT  JOIN ' + QUOTENAME(@db) + N'.sys.sql_modules AS m ON m.object_id = p.object_id
        WHERE p.is_ms_shipped = 0
          AND (   p.name LIKE ''%etl%''       OR p.name LIKE ''%load%''
               OR p.name LIKE ''%import%''    OR p.name LIKE ''%export%''
               OR p.name LIKE ''%extract%''   OR p.name LIKE ''%transform%''
               OR p.name LIKE ''%stage%''     OR p.name LIKE ''%stg%''
               OR p.name LIKE ''%ingest%''    OR p.name LIKE ''%merge%''
               OR p.name LIKE ''%upsert%''    OR p.name LIKE ''%sync%''
               OR p.name LIKE ''%refresh%''
               OR s.name IN (''etl'', ''stg'', ''staging'', ''load'', ''ingest''));';

        EXEC sp_executesql @sql;

        SET @sql = N'
        INSERT INTO #Cfg (DbName, ConfigObjects)
        SELECT ' + QUOTENAME(@db, '''') + N', COUNT(*)
        FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
        INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND (   (t.name LIKE ''%etl%'' AND (t.name LIKE ''%config%'' OR t.name LIKE ''%control%''
                                           OR t.name LIKE ''%meta%''   OR t.name LIKE ''%map%''))
               OR t.name LIKE ''%load%config%''  OR t.name LIKE ''%load%control%''
               OR t.name LIKE ''%package%config%''
               OR t.name LIKE ''%watermark%''    OR t.name LIKE ''%high%water%''
               OR t.name LIKE ''%metadata%''
               OR t.name LIKE ''%column%mapping%'' OR t.name LIKE ''%table%mapping%''
               OR t.name LIKE ''%source%definition%''
               OR s.name IN (''etl'', ''meta'', ''metadata'', ''control'', ''framework''));';

        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        /* Database unreadable or offline mid-scan - skip it and continue. */
        SET @sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* ---- 3. SSIS catalog / legacy package inventory --------------------------- */
IF @IsAzureSqlDb = 0
BEGIN
    IF DB_ID('SSISDB') IS NOT NULL AND HAS_DBACCESS('SSISDB') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            SELECT @proj = (SELECT COUNT(*) FROM SSISDB.catalog.projects),
                   @pkg  = (SELECT COUNT(*) FROM SSISDB.catalog.packages),
                   @parm = (SELECT COUNT(DISTINCT op.object_name)
                            FROM SSISDB.catalog.object_parameters AS op
                            WHERE op.object_type = 30);';
            EXEC sp_executesql @sql,
                 N'@proj INT OUTPUT, @pkg INT OUTPUT, @parm INT OUTPUT',
                 @proj = @SsisProjects OUTPUT, @pkg = @SsisPackages OUTPUT, @parm = @SsisParamPackages OUTPUT;
        END TRY
        BEGIN CATCH
            SET @SsisProjects = 0; SET @SsisPackages = 0; SET @SsisParamPackages = 0;
        END CATCH
    END

    IF OBJECT_ID('msdb.dbo.sysssispackages') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT @legacy = COUNT(*) FROM msdb.dbo.sysssispackages;';
            EXEC sp_executesql @sql, N'@legacy INT OUTPUT', @legacy = @LegacyPackages OUTPUT;
        END TRY
        BEGIN CATCH
            SET @LegacyPackages = 0;
        END CATCH
    END
END

/* ---- 4. Aggregate reuse and duplication signals --------------------------- */
SELECT @TotalEtlProcs = COUNT(*),
       @ReusableProcs = ISNULL(SUM(CASE WHEN HasTemplateParam = 1 OR HasDynamicMetadata = 1 THEN 1 ELSE 0 END), 0)
FROM #Etl;

SELECT @ConfigTables = ISNULL(SUM(ConfigObjects), 0) FROM #Cfg;

;WITH fam AS
(
    SELECT DbName,
           FamilyKey,
           COUNT(*) AS Members,
           SUM(CASE WHEN HasTemplateParam = 1 OR HasDynamicMetadata = 1 THEN 1 ELSE 0 END) AS ReusableMembers
    FROM #Etl
    GROUP BY DbName, FamilyKey
)
SELECT @CopyPasteFamilies = COUNT(*),
       @CopyPasteProcs    = ISNULL(SUM(Members), 0)
FROM fam
WHERE Members >= 3 AND ReusableMembers = 0;

;WITH fam AS
(
    SELECT DbName,
           FamilyKey,
           COUNT(*) AS Members,
           SUM(CASE WHEN HasTemplateParam = 1 OR HasDynamicMetadata = 1 THEN 1 ELSE 0 END) AS ReusableMembers
    FROM #Etl
    GROUP BY DbName, FamilyKey
)
SELECT TOP (1) @TopFamily = DbName + N'.' + FamilyKey + N'* = '
                          + CAST(Members AS NVARCHAR(20)) + N' non-parameterised sibling procedures'
FROM fam
WHERE Members >= 3 AND ReusableMembers = 0
ORDER BY Members DESC, DbName, FamilyKey;

SET @CopyPasteFamilies = ISNULL(@CopyPasteFamilies, 0);
SET @CopyPasteProcs    = ISNULL(@CopyPasteProcs, 0);

SET @ReuseSignals = CASE WHEN @ReusableProcs     > 0 THEN 1 ELSE 0 END
                  + CASE WHEN @ConfigTables      > 0 THEN 1 ELSE 0 END
                  + CASE WHEN @SsisParamPackages > 0 THEN 1 ELSE 0 END;

SELECT @DbList = STUFF((SELECT N', ' + DbName
                        FROM #Db
                        ORDER BY DbName
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = CASE
                          WHEN @DbList IS NULL THEN N'No accessible user databases'
                          WHEN LEN(@DbList) > 400 THEN LEFT(@DbList, 400) + N'... (' + CAST(@DbCount AS NVARCHAR(20)) + N' databases)'
                          ELSE @DbList
                       END;

/* ---- 5. Scoring ----------------------------------------------------------- */
IF @TotalEtlProcs = 0 AND @SsisPackages = 0 AND @LegacyPackages = 0 AND @ConfigTables = 0
BEGIN
    SET @Score   = 0;
    SET @Verdict = N'No ETL code artifacts (ETL-named procedures, SSIS packages or ETL control tables) were discoverable from instance metadata, so component reuse cannot be evidenced here - the ETL layer is likely external (ADF, Databricks, Fabric, third-party tooling) and must be reviewed at source.';
END
ELSE IF @ReuseSignals >= 2 AND @CopyPasteFamilies = 0
BEGIN
    SET @Score   = 3;
    SET @Verdict = N'ETL logic is built from templated, parameter- or metadata-driven components and no copy-paste-per-table naming families were detected.';
END
ELSE IF @ReuseSignals >= 1 AND @CopyPasteFamilies <= 2
BEGIN
    SET @Score   = 2;
    SET @Verdict = N'Some templating exists, but per-table duplication is still present alongside it - reuse is partial and inconsistently applied.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Verdict = N'ETL code is dominated by hard-coded, per-table procedures with no parameterised template, metadata-driven dynamic SQL or configuration-table framework.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) for ETL code artifacts. '
             + N'ETL-named procedures: ' + CAST(@TotalEtlProcs AS NVARCHAR(20))
             + N'; reusable (templated parameter or metadata-driven dynamic SQL): ' + CAST(@ReusableProcs AS NVARCHAR(20))
             + N'; ETL config/control/metadata tables: ' + CAST(@ConfigTables AS NVARCHAR(20))
             + N'; SSIS catalog projects/packages: ' + CAST(@SsisProjects AS NVARCHAR(20)) + N'/' + CAST(@SsisPackages AS NVARCHAR(20))
             + N' (packages exposing parameters: ' + CAST(@SsisParamPackages AS NVARCHAR(20)) + N')'
             + N'; legacy msdb SSIS packages: ' + CAST(@LegacyPackages AS NVARCHAR(20))
             + N'. Copy-paste indicator: ' + CAST(@CopyPasteFamilies AS NVARCHAR(20))
             + N' naming family/families of 3+ non-parameterised sibling procedures covering '
             + CAST(@CopyPasteProcs AS NVARCHAR(20)) + N' procedure(s)'
             + ISNULL(N' (largest: ' + @TopFamily + N')', N'')
             + N'. Reuse signals present: ' + CAST(@ReuseSignals AS NVARCHAR(20)) + N' of 3. '
             + CASE WHEN @IsAzureSqlDb = 1
                    THEN N'Azure SQL Database/Synapse detected: scope limited to the current database and the SSIS catalog is not available. '
                    ELSE N'' END
             + @Verdict;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Etl') IS NOT NULL DROP TABLE #Etl;
IF OBJECT_ID('tempdb..#Cfg') IS NOT NULL DROP TABLE #Cfg;
IF OBJECT_ID('tempdb..#Db')  IS NOT NULL DROP TABLE #Db;