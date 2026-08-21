/* ==========================================================================
   Checklist Item : 2.1.2 - ETL packages/pipelines follow consistent naming conventions
   Scope          : SERVER
   Access         : READ-ONLY (system catalog views only; temp tables for staging)
   Output         : Result, Score, DatabaseQueried, Finding
   ========================================================================== */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb    bit            = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried nvarchar(256)  = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5
                                               THEN DB_NAME()
                                               ELSE N'msdb, SSISDB' END;
DECLARE @sql             nvarchar(max);

IF OBJECT_ID('tempdb..#EtlArtifacts') IS NOT NULL DROP TABLE #EtlArtifacts;
CREATE TABLE #EtlArtifacts
(
    SourceType    nvarchar(60)  NOT NULL,
    ContainerName nvarchar(512) NULL,
    ArtifactName  nvarchar(260) NOT NULL
);

IF @IsAzureSqlDb = 0
BEGIN
    /* ---------- Legacy SSIS packages stored in msdb ---------- */
    IF DB_ID(N'msdb') IS NOT NULL AND HAS_DBACCESS(N'msdb') = 1
    BEGIN
        BEGIN TRY
            IF OBJECT_ID(N'msdb.dbo.sysssispackages', N'U') IS NOT NULL
            BEGIN
                SET @sql = N'SELECT N''SSIS Package (msdb)'', ISNULL(f.foldername, N''(root)''), p.name
                             FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysssispackages AS p
                             LEFT JOIN ' + QUOTENAME(N'msdb') + N'.dbo.sysssispackagefolders AS f
                                    ON f.folderid = p.folderid;';

                INSERT INTO #EtlArtifacts (SourceType, ContainerName, ArtifactName)
                EXEC sys.sp_executesql @sql;
            END
        END TRY
        BEGIN CATCH
            /* package store not readable - leave inventory unchanged */
        END CATCH;

        /* ---------- SQL Server Agent jobs running SSIS/ETL steps ---------- */
        BEGIN TRY
            IF OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NOT NULL
               AND OBJECT_ID(N'msdb.dbo.sysjobsteps', N'U') IS NOT NULL
            BEGIN
                SET @sql = N'SELECT DISTINCT N''ETL Agent Job'', N''SQL Server Agent'', j.name
                             FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobs AS j
                             INNER JOIN ' + QUOTENAME(N'msdb') + N'.dbo.sysjobsteps AS s
                                     ON s.job_id = j.job_id
                             WHERE s.subsystem IN (N''SSIS'', N''Dts'');';

                INSERT INTO #EtlArtifacts (SourceType, ContainerName, ArtifactName)
                EXEC sys.sp_executesql @sql;
            END
        END TRY
        BEGIN CATCH
            /* Agent metadata not readable - leave inventory unchanged */
        END CATCH;
    END

    /* ---------- SSIS Catalog (project deployment model) ---------- */
    IF DB_ID(N'SSISDB') IS NOT NULL AND HAS_DBACCESS(N'SSISDB') = 1
    BEGIN
        BEGIN TRY
            IF OBJECT_ID(N'SSISDB.catalog.packages') IS NOT NULL
            BEGIN
                SET @sql = N'SELECT N''SSIS Package (SSISDB)'', fo.name + N''/'' + pr.name, pk.name
                             FROM ' + QUOTENAME(N'SSISDB') + N'.catalog.packages AS pk
                             INNER JOIN ' + QUOTENAME(N'SSISDB') + N'.catalog.projects AS pr
                                     ON pr.project_id = pk.project_id
                             INNER JOIN ' + QUOTENAME(N'SSISDB') + N'.catalog.folders AS fo
                                     ON fo.folder_id = pr.folder_id;';

                INSERT INTO #EtlArtifacts (SourceType, ContainerName, ArtifactName)
                EXEC sys.sp_executesql @sql;
            END
        END TRY
        BEGIN CATCH
            /* SSISDB catalog not readable - leave inventory unchanged */
        END CATCH;
    END
END

/* ---------- Evaluate each artifact name against the convention rules ---------- */
IF OBJECT_ID('tempdb..#Analysis') IS NOT NULL DROP TABLE #Analysis;
CREATE TABLE #Analysis
(
    SourceType   nvarchar(60)  NOT NULL,
    ArtifactName nvarchar(260) NOT NULL,
    Prefix       nvarchar(260) NOT NULL,
    IsConforming bit           NOT NULL,
    Issue        nvarchar(200) NOT NULL
);

INSERT INTO #Analysis (SourceType, ArtifactName, Prefix, IsConforming, Issue)
SELECT  b.SourceType,
        b.ArtifactName,
        p.Prefix,
        CASE WHEN i.Issue = N'' THEN 1 ELSE 0 END,
        i.Issue
FROM (
        SELECT  a.SourceType,
                a.ArtifactName,
                BaseName = CASE WHEN a.ArtifactName LIKE N'%.dtsx'
                                THEN LEFT(a.ArtifactName, LEN(a.ArtifactName) - 5)
                                ELSE a.ArtifactName END
        FROM #EtlArtifacts AS a
     ) AS b
CROSS APPLY (
        SELECT Prefix = UPPER(LEFT(b.BaseName,
                    CASE WHEN PATINDEX(N'%[_-]%', b.BaseName) > 0
                         THEN PATINDEX(N'%[_-]%', b.BaseName) - 1
                         ELSE LEN(b.BaseName) END))
     ) AS p
CROSS APPLY (
        SELECT Issue = CASE
                 WHEN LEN(LTRIM(RTRIM(b.BaseName))) = 0                        THEN N'Empty name'
                 WHEN b.BaseName LIKE N'%[ ]%'                                 THEN N'Contains spaces'
                 WHEN b.BaseName = N'Package'
                      OR b.BaseName LIKE N'Package[0-9]%'
                      OR b.BaseName LIKE N'[Nn]ew [Pp]ackage%'                 THEN N'Default auto-generated name'
                 WHEN b.BaseName LIKE N'[Cc]opy of %'
                      OR b.BaseName LIKE N'%- [Cc]opy'                         THEN N'Copy-of style name'
                 WHEN b.BaseName LIKE N'%[^A-Za-z0-9_-]%'                      THEN N'Characters outside A-Z 0-9 _ -'
                 WHEN b.BaseName LIKE N'%[_]%' AND b.BaseName LIKE N'%[-]%'    THEN N'Mixed word separators (_ and -)'
                 ELSE N'' END
     ) AS i;

DECLARE @Total          int = 0,
        @Conforming     int = 0,
        @NonConforming  int = 0,
        @DominantCount  int = 0,
        @DistinctPrefix int = 0;
DECLARE @DominantPrefix nvarchar(260) = N'(none)';

SELECT  @Total      = COUNT(*),
        @Conforming = SUM(CASE WHEN IsConforming = 1 THEN 1 ELSE 0 END)
FROM #Analysis;

SET @Total         = ISNULL(@Total, 0);
SET @Conforming    = ISNULL(@Conforming, 0);
SET @NonConforming = @Total - @Conforming;

SELECT TOP (1) @DominantPrefix = Prefix, @DominantCount = COUNT(*)
FROM #Analysis
GROUP BY Prefix
ORDER BY COUNT(*) DESC, Prefix;

SELECT @DistinctPrefix = COUNT(DISTINCT Prefix) FROM #Analysis;

DECLARE @ConformPct decimal(5,1) =
        CASE WHEN @Total = 0 THEN CONVERT(decimal(5,1), 0)
             ELSE CONVERT(decimal(5,1), 100.0 * @Conforming / @Total) END;
DECLARE @PrefixPct decimal(5,1) =
        CASE WHEN @Total = 0 THEN CONVERT(decimal(5,1), 0)
             ELSE CONVERT(decimal(5,1), 100.0 * ISNULL(@DominantCount, 0) / @Total) END;

DECLARE @Examples nvarchar(1500);
SET @Examples = STUFF((
        SELECT TOP (5) N'; ' + a.ArtifactName + N' [' + a.Issue + N']'
        FROM #Analysis AS a
        WHERE a.IsConforming = 0
        ORDER BY a.ArtifactName
        FOR XML PATH(N''), TYPE).value(N'.[1]', N'nvarchar(1500)'), 1, 2, N'');
SET @Examples = ISNULL(@Examples, N'none');

DECLARE @Stats nvarchar(1000) =
        N'Artifacts inspected: ' + CONVERT(nvarchar(20), @Total)
      + N'; conforming: ' + CONVERT(nvarchar(20), @Conforming)
      + N' (' + CONVERT(nvarchar(20), @ConformPct) + N'%)'
      + N'; non-conforming: ' + CONVERT(nvarchar(20), @NonConforming)
      + N'; distinct prefixes: ' + CONVERT(nvarchar(20), @DistinctPrefix)
      + N'; dominant prefix ''' + @DominantPrefix + N''' covers '
      + CONVERT(nvarchar(20), @PrefixPct) + N'% of artifacts.';

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(4000);

IF @Total = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CASE WHEN @IsAzureSqlDb = 1
        THEN N'Engine is Azure SQL Database (EngineEdition 5): msdb, SQL Server Agent and the SSIS catalog do not exist and cross-database enumeration is not supported, so no ETL artifact names could be inspected from this connection. Naming conventions must be evidenced in the external orchestration platform (Azure Data Factory / Synapse / Fabric pipelines).'
        ELSE N'No ETL artifacts were discoverable on this instance: msdb.dbo.sysssispackages returned no rows or is absent, the SSISDB catalog is not installed or not accessible, and no SQL Agent job step uses the SSIS/Dts subsystem. Either ETL runs on an external platform or the audit login lacks permission on msdb/SSISDB, so no naming-convention evidence exists.' END;
END
ELSE IF @NonConforming = 0 AND @PrefixPct >= 80.0
BEGIN
    SET @Score = 3;
    SET @Finding = N'All discovered ETL packages/pipelines follow a consistent naming convention. ' + @Stats;
END
ELSE IF @ConformPct >= 80.0 AND @PrefixPct >= 50.0
BEGIN
    SET @Score = 2;
    SET @Finding = N'A naming convention is largely in place but is not applied uniformly across all ETL artifacts. ' + @Stats
                 + N' Example non-conforming names: ' + @Examples;
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'ETL package/pipeline names do not follow a consistent convention. ' + @Stats
                 + N' Example non-conforming names: ' + @Examples;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT  @Result          AS Result,
        @Score           AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding         AS Finding;