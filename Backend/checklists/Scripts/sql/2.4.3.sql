/* Checklist 2.4.3 - Indexes/constraints managed during large loads (disable/rebuild where beneficial) */
/* Read-only: queries catalog views only; writes nothing outside session-scoped temp tables. */
SET NOCOUNT ON;

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Scores') IS NOT NULL DROP TABLE #Scores;

CREATE TABLE #Targets (DbName sysname NOT NULL);

CREATE TABLE #Findings (
    DbName                sysname NOT NULL,
    ManagedLoadModules    int NULL,
    MgmtModules           int NULL,
    LoadModules           int NULL,
    DisabledIndexes       int NULL,
    UntrustedConstraints  int NULL,
    ErrorText             nvarchar(400) NULL
);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Targets (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Targets (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.user_access = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db sysname, @prefix nvarchar(300), @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #Targets ORDER BY DbName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
SELECT
    @p_db AS DbName,
    m.ManagedLoadModules,
    m.MgmtModules,
    m.LoadModules,
    (SELECT COUNT(*)
     FROM ' + @prefix + N'sys.indexes AS i
     INNER JOIN ' + @prefix + N'sys.objects AS o ON o.object_id = i.object_id
     WHERE i.is_disabled = 1 AND i.index_id > 0 AND o.is_ms_shipped = 0 AND o.type = ''U'') AS DisabledIndexes,
    (SELECT COUNT(*)
     FROM ' + @prefix + N'sys.foreign_keys AS fk
     WHERE fk.is_not_trusted = 1 OR fk.is_disabled = 1)
    +
    (SELECT COUNT(*)
     FROM ' + @prefix + N'sys.check_constraints AS cc
     WHERE cc.is_not_trusted = 1 OR cc.is_disabled = 1) AS UntrustedConstraints
FROM (
    SELECT
        ISNULL(SUM(CASE WHEN d.HasLoad = 1 AND d.HasMgmt = 1 THEN 1 ELSE 0 END), 0) AS ManagedLoadModules,
        ISNULL(SUM(CASE WHEN d.HasMgmt = 1 THEN 1 ELSE 0 END), 0) AS MgmtModules,
        ISNULL(SUM(CASE WHEN d.HasLoad = 1 THEN 1 ELSE 0 END), 0) AS LoadModules
    FROM (
        SELECT
            CASE WHEN UPPER(sm.definition) LIKE N''%BULK INSERT%''
                   OR UPPER(sm.definition) LIKE N''%OPENROWSET%''
                   OR UPPER(sm.definition) LIKE N''%TABLOCK%''
                   OR UPPER(sm.definition) LIKE N''%TRUNCATE TABLE%''
                   OR UPPER(sm.definition) LIKE N''%SWITCH PARTITION%''
                   OR UPPER(sm.definition) LIKE N''%SWITCH TO%''
                 THEN 1 ELSE 0 END AS HasLoad,
            CASE WHEN UPPER(sm.definition) LIKE N''%ALTER INDEX%DISABLE%''
                   OR UPPER(sm.definition) LIKE N''%ALTER INDEX%REBUILD%''
                   OR UPPER(sm.definition) LIKE N''%ALTER INDEX%REORGANIZE%''
                   OR UPPER(sm.definition) LIKE N''%NOCHECK CONSTRAINT%''
                   OR UPPER(sm.definition) LIKE N''%CHECK CONSTRAINT%''
                   OR UPPER(sm.definition) LIKE N''%DROP INDEX%''
                 THEN 1 ELSE 0 END AS HasMgmt
        FROM ' + @prefix + N'sys.sql_modules AS sm
        INNER JOIN ' + @prefix + N'sys.objects AS o2 ON o2.object_id = sm.object_id
        WHERE o2.is_ms_shipped = 0
          AND o2.type IN (''P'', ''TR'', ''FN'', ''TF'', ''IF'')
    ) AS d
) AS m;';

    BEGIN TRY
        INSERT INTO #Findings (DbName, ManagedLoadModules, MgmtModules, LoadModules, DisabledIndexes, UntrustedConstraints)
        EXEC sp_executesql @sql, N'@p_db sysname', @p_db = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #Findings (DbName, ErrorText) VALUES (@db, LEFT(ERROR_MESSAGE(), 400));
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

SELECT
    f.DbName,
    f.ManagedLoadModules,
    f.MgmtModules,
    f.LoadModules,
    f.DisabledIndexes,
    f.UntrustedConstraints,
    f.ErrorText,
    CASE
        WHEN f.ErrorText IS NOT NULL THEN 1
        WHEN f.ManagedLoadModules > 0 AND f.DisabledIndexes = 0 AND f.UntrustedConstraints = 0 THEN 3
        WHEN f.ManagedLoadModules > 0 THEN 2
        WHEN f.LoadModules = 0 AND f.MgmtModules = 0 AND f.DisabledIndexes = 0 AND f.UntrustedConstraints = 0 THEN 2
        WHEN f.LoadModules > 0 AND (f.DisabledIndexes > 0 OR f.UntrustedConstraints > 0) THEN 0
        WHEN f.LoadModules > 0 THEN 1
        WHEN f.DisabledIndexes > 0 OR f.UntrustedConstraints > 0 THEN 1
        ELSE 2
    END AS DbScore
INTO #Scores
FROM #Findings AS f;

DECLARE @Result varchar(20),
        @Score int,
        @DatabaseQueried nvarchar(max),
        @Finding nvarchar(max),
        @DbCount int,
        @Detail nvarchar(max);

SELECT @DbCount = COUNT(*), @Score = MIN(s.DbScore) FROM #Scores AS s;

IF ISNULL(@DbCount, 0) = 0
BEGIN
    SET @Score = 1;
    SET @Result = 'NeedsReview';
    SET @DatabaseQueried = ISNULL(CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')), N'Unknown');
    SET @Finding = N'No accessible user database was found on this instance, so index and constraint management during large loads could not be assessed. Grant read access to the target databases and re-run this check.';
END
ELSE
BEGIN
    SET @Result = CASE WHEN @Score = 3 THEN 'Pass' WHEN @Score = 2 THEN 'NeedsReview' ELSE 'Fail' END;

    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + s.DbName
        FROM #Scores AS s
        ORDER BY s.DbName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SELECT @Detail = STUFF((
        SELECT N'; ' + s.DbName + N' (score ' + CAST(s.DbScore AS varchar(2)) + N': '
               + CASE
                     WHEN s.ErrorText IS NOT NULL THEN N'metadata unreadable - ' + s.ErrorText
                     ELSE N'load modules managing indexes/constraints ' + CAST(s.ManagedLoadModules AS varchar(10))
                          + N', bulk-load modules ' + CAST(s.LoadModules AS varchar(10))
                          + N', modules with index/constraint management ' + CAST(s.MgmtModules AS varchar(10))
                          + N', indexes left disabled ' + CAST(s.DisabledIndexes AS varchar(10))
                          + N', constraints disabled/untrusted ' + CAST(s.UntrustedConstraints AS varchar(10))
                 END
               + N')'
        FROM #Scores AS s
        ORDER BY s.DbScore, s.DbName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Finding = N'Assessed ' + CAST(@DbCount AS varchar(10)) + N' accessible user database(s). '
        + CASE
              WHEN @Score = 3 THEN N'Every database has load routines that disable/rebuild indexes or manage constraints, and no index or constraint was left disabled or untrusted. '
              WHEN @Score = 2 THEN N'At least one database either left indexes/constraints disabled or untrusted after a managed load, or shows no bulk-load activity at all, so index/constraint handling during large loads needs manual confirmation (external ETL tooling would not be visible here). '
              WHEN @Score = 1 THEN N'At least one database performs bulk loads without any index or constraint management, or has indexes/constraints left disabled or untrusted with no managing routine. '
              ELSE N'At least one database performs bulk loads with no index or constraint management AND has indexes left disabled or constraints left disabled/untrusted, so loaded data is unverified and query plans are degraded. '
          END
        + N'Per-database evidence: ' + LEFT(ISNULL(@Detail, N'none'), 3000) + N'.';
END

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;