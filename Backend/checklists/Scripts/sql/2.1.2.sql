SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#EtlNames') IS NOT NULL DROP TABLE #EtlNames;
CREATE TABLE #EtlNames (
    SourceSystem nvarchar(50) NOT NULL,
    ObjectType   nvarchar(50) NOT NULL,
    ParentPath   nvarchar(400) NULL,
    ObjectName   nvarchar(256) NOT NULL
);

/* SSISDB catalog packages / projects / folders */
IF DB_ID(N'SSISDB') IS NOT NULL
BEGIN
    BEGIN TRY
        INSERT INTO #EtlNames (SourceSystem, ObjectType, ParentPath, ObjectName)
        SELECT
            N'SSISDB',
            N'Folder',
            NULL,
            f.name
        FROM SSISDB.catalog.folders AS f;

        INSERT INTO #EtlNames (SourceSystem, ObjectType, ParentPath, ObjectName)
        SELECT
            N'SSISDB',
            N'Project',
            f.name,
            p.name
        FROM SSISDB.catalog.projects AS p
        INNER JOIN SSISDB.catalog.folders AS f
            ON f.folder_id = p.folder_id;

        INSERT INTO #EtlNames (SourceSystem, ObjectType, ParentPath, ObjectName)
        SELECT
            N'SSISDB',
            N'Package',
            f.name + N'/' + p.name,
            pkg.name
        FROM SSISDB.catalog.packages AS pkg
        INNER JOIN SSISDB.catalog.projects AS p
            ON p.project_id = pkg.project_id
        INNER JOIN SSISDB.catalog.folders AS f
            ON f.folder_id = p.folder_id;
    END TRY
    BEGIN CATCH
        /* SSISDB present but not queryable — continue with other sources */
    END CATCH
END;

/* Legacy msdb package store */
IF OBJECT_ID(N'msdb.dbo.sysssispackages') IS NOT NULL
BEGIN
    BEGIN TRY
        INSERT INTO #EtlNames (SourceSystem, ObjectType, ParentPath, ObjectName)
        SELECT
            N'msdb',
            N'LegacyPackage',
            COALESCE(f.foldername, N'/'),
            p.name
        FROM msdb.dbo.sysssispackages AS p
        LEFT JOIN msdb.dbo.sysssispackagefolders AS f
            ON f.folderid = p.folderid
        WHERE p.name NOT LIKE N'msdb_org%';
    END TRY
    BEGIN CATCH
    END CATCH
END;

/* SQL Agent jobs that appear ETL-related */
IF OBJECT_ID(N'msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    INSERT INTO #EtlNames (SourceSystem, ObjectType, ParentPath, ObjectName)
    SELECT
        N'SQLAgent',
        N'Job',
        NULL,
        j.name
    FROM msdb.dbo.sysjobs AS j
    WHERE j.name LIKE N'%ETL%'
       OR j.name LIKE N'%SSIS%'
       OR j.name LIKE N'%DF[_]%'
       OR j.name LIKE N'%DataFlow%'
       OR j.name LIKE N'%Data Flow%'
       OR j.name LIKE N'%Load%'
       OR j.name LIKE N'%Ingest%'
       OR j.name LIKE N'%Pipeline%'
       OR j.name LIKE N'%Staging%'
       OR j.name LIKE N'%Extract%'
       OR j.name LIKE N'%Transform%';
END;

DECLARE @Total int = (SELECT COUNT(*) FROM #EtlNames);
DECLARE @PackageCnt int = (SELECT COUNT(*) FROM #EtlNames WHERE ObjectType IN (N'Package', N'LegacyPackage'));
DECLARE @ProjectCnt int = (SELECT COUNT(*) FROM #EtlNames WHERE ObjectType = N'Project');
DECLARE @FolderCnt int = (SELECT COUNT(*) FROM #EtlNames WHERE ObjectType = N'Folder');
DECLARE @JobCnt int = (SELECT COUNT(*) FROM #EtlNames WHERE ObjectType = N'Job');

IF OBJECT_ID('tempdb..#NameMetrics') IS NOT NULL DROP TABLE #NameMetrics;
CREATE TABLE #NameMetrics (
    ObjectName nvarchar(256) NOT NULL,
    ObjectType nvarchar(50) NOT NULL,
    HasSeparator bit NOT NULL,
    HasPrefixToken bit NOT NULL,
    IsPascalOrSnake bit NOT NULL,
    HasSpace bit NOT NULL,
    HasDefaultName bit NOT NULL,
    NameLength int NOT NULL,
    Prefix3 nvarchar(3) NULL,
    PrefixToken nvarchar(50) NULL
);

INSERT INTO #NameMetrics (
    ObjectName, ObjectType, HasSeparator, HasPrefixToken, IsPascalOrSnake,
    HasSpace, HasDefaultName, NameLength, Prefix3, PrefixToken
)
SELECT
    n.ObjectName,
    n.ObjectType,
    CASE WHEN n.ObjectName LIKE N'%[_-]%' THEN 1 ELSE 0 END,
    CASE
        WHEN n.ObjectName LIKE N'ETL%'
          OR n.ObjectName LIKE N'SSIS%'
          OR n.ObjectName LIKE N'Dim%'
          OR n.ObjectName LIKE N'Fact%'
          OR n.ObjectName LIKE N'Stg%'
          OR n.ObjectName LIKE N'Stg[_]%'
          OR n.ObjectName LIKE N'Staging%'
          OR n.ObjectName LIKE N'Load%'
          OR n.ObjectName LIKE N'Extract%'
          OR n.ObjectName LIKE N'Transform%'
          OR n.ObjectName LIKE N'Pipe%'
          OR n.ObjectName LIKE N'DWH%'
          OR n.ObjectName LIKE N'DW[_]%'
          OR n.ObjectName LIKE N'RAW%'
          OR n.ObjectName LIKE N'ODS%'
        THEN 1 ELSE 0
    END,
    CASE
        WHEN n.ObjectName LIKE N'%[_]%[A-Za-z]%'
          OR (n.ObjectName LIKE N'[A-Z]%' AND n.ObjectName NOT LIKE N'% %' AND n.ObjectName LIKE N'%[a-z]%[A-Z]%')
        THEN 1 ELSE 0
    END,
    CASE WHEN n.ObjectName LIKE N'% %' THEN 1 ELSE 0 END,
    CASE
        WHEN n.ObjectName LIKE N'Package%'
          OR n.ObjectName LIKE N'Package1%'
          OR n.ObjectName IN (N'Package', N'Package1', N'Project1', N'Folder1')
          OR n.ObjectName LIKE N'New Package%'
          OR n.ObjectName LIKE N'NewProject%'
        THEN 1 ELSE 0
    END,
    LEN(n.ObjectName),
    LEFT(n.ObjectName, 3),
    CASE
        WHEN CHARINDEX(N'_', n.ObjectName) > 1 THEN LEFT(n.ObjectName, CHARINDEX(N'_', n.ObjectName) - 1)
        WHEN CHARINDEX(N'-', n.ObjectName) > 1 THEN LEFT(n.ObjectName, CHARINDEX(N'-', n.ObjectName) - 1)
        WHEN n.ObjectName LIKE N'ETL%' THEN N'ETL'
        WHEN n.ObjectName LIKE N'SSIS%' THEN N'SSIS'
        ELSE LEFT(n.ObjectName, CASE WHEN LEN(n.ObjectName) >= 3 THEN 3 ELSE LEN(n.ObjectName) END)
    END
FROM #EtlNames AS n;

DECLARE @DefaultNameCnt int = (SELECT COUNT(*) FROM #NameMetrics WHERE HasDefaultName = 1);
DECLARE @SpaceCnt int = (SELECT COUNT(*) FROM #NameMetrics WHERE HasSpace = 1);
DECLARE @SeparatorCnt int = (SELECT COUNT(*) FROM #NameMetrics WHERE HasSeparator = 1);
DECLARE @StyleCnt int = (SELECT COUNT(*) FROM #NameMetrics WHERE IsPascalOrSnake = 1);
DECLARE @PrefixTokenCnt int = (SELECT COUNT(*) FROM #NameMetrics WHERE HasPrefixToken = 1);

DECLARE @SepRatio float = CASE WHEN @Total > 0 THEN 1.0 * @SeparatorCnt / @Total ELSE 0 END;
DECLARE @StyleRatio float = CASE WHEN @Total > 0 THEN 1.0 * @StyleCnt / @Total ELSE 0 END;
DECLARE @SpaceRatio float = CASE WHEN @Total > 0 THEN 1.0 * @SpaceCnt / @Total ELSE 0 END;
DECLARE @DefaultRatio float = CASE WHEN @Total > 0 THEN 1.0 * @DefaultNameCnt / @Total ELSE 0 END;
DECLARE @PrefixRatio float = CASE WHEN @Total > 0 THEN 1.0 * @PrefixTokenCnt / @Total ELSE 0 END;

DECLARE @TopPrefixCnt int = 0;
DECLARE @TopPrefix nvarchar(50) = NULL;
SELECT TOP (1)
    @TopPrefix = PrefixToken,
    @TopPrefixCnt = COUNT(*)
FROM #NameMetrics
WHERE PrefixToken IS NOT NULL AND LEN(PrefixToken) >= 2
GROUP BY PrefixToken
ORDER BY COUNT(*) DESC, PrefixToken;

DECLARE @PrefixConcentration float = CASE WHEN @Total > 0 THEN 1.0 * ISNULL(@TopPrefixCnt, 0) / @Total ELSE 0 END;

DECLARE @ConsistencyScore float = 0;
IF @Total > 0
BEGIN
    SET @ConsistencyScore =
          (CASE WHEN @SepRatio >= 0.7 OR @StyleRatio >= 0.7 THEN 0.35
                WHEN @SepRatio >= 0.4 OR @StyleRatio >= 0.4 THEN 0.20
                ELSE 0.05 END)
        + (CASE WHEN @PrefixConcentration >= 0.5 THEN 0.25
                WHEN @PrefixConcentration >= 0.3 THEN 0.15
                WHEN @PrefixRatio >= 0.4 THEN 0.10
                ELSE 0.0 END)
        + (CASE WHEN @SpaceRatio <= 0.1 THEN 0.20
                WHEN @SpaceRatio <= 0.3 THEN 0.10
                ELSE 0.0 END)
        + (CASE WHEN @DefaultRatio = 0 THEN 0.20
                WHEN @DefaultRatio <= 0.1 THEN 0.10
                ELSE 0.0 END);
END;

DECLARE @Score int;
DECLARE @Finding nvarchar(max);

IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No SSIS catalog packages/projects, legacy msdb packages, or ETL-like SQL Agent jobs were found on this instance. Naming-convention consistency is not applicable (no ETL package/pipeline name inventory to evaluate).';
END
ELSE
BEGIN
    IF @ConsistencyScore >= 0.80 AND @DefaultRatio = 0 AND @SpaceRatio <= 0.15
        SET @Score = 3;
    ELSE IF @ConsistencyScore >= 0.55 AND @DefaultRatio <= 0.1
        SET @Score = 2;
    ELSE IF @ConsistencyScore >= 0.30
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding =
        N'ETL name inventory: total=' + CAST(@Total AS nvarchar(20))
        + N' (SSIS packages=' + CAST(@PackageCnt AS nvarchar(20))
        + N', projects=' + CAST(@ProjectCnt AS nvarchar(20))
        + N', folders=' + CAST(@FolderCnt AS nvarchar(20))
        + N', ETL-like Agent jobs=' + CAST(@JobCnt AS nvarchar(20))
        + N'). ConsistencyScore=' + CONVERT(nvarchar(20), ROUND(@ConsistencyScore, 2))
        + N'; separatorStyleRatio=' + CONVERT(nvarchar(20), ROUND(@SepRatio, 2))
        + N'; structuredStyleRatio=' + CONVERT(nvarchar(20), ROUND(@StyleRatio, 2))
        + N'; spaceNameRatio=' + CONVERT(nvarchar(20), ROUND(@SpaceRatio, 2))
        + N'; defaultNameRatio=' + CONVERT(nvarchar(20), ROUND(@DefaultRatio, 2))
        + N'; topPrefix=' + COALESCE(@TopPrefix, N'n/a')
        + N' (concentration=' + CONVERT(nvarchar(20), ROUND(@PrefixConcentration, 2))
        + N'). Default/generic names=' + CAST(@DefaultNameCnt AS nvarchar(20))
        + N'. Score reflects cross-object naming cohesion for packages/pipelines/jobs, not presence of a written standard.';
END;

DECLARE @Result nvarchar(10);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    N'SERVER' AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #NameMetrics;
DROP TABLE #EtlNames;