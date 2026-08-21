SET NOCOUNT ON;

DECLARE @IsSingleDb BIT =
    CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) IN (5, 6, 9, 11) THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Res') IS NOT NULL DROP TABLE #Res;
IF OBJECT_ID('tempdb..#Tier') IS NOT NULL DROP TABLE #Tier;

CREATE TABLE #DbList (DbName SYSNAME NOT NULL);

CREATE TABLE #Res
(
    DbName            SYSNAME       NOT NULL,
    UserTables        INT           NULL,
    DedupModules      INT           NULL,
    StagingUniqueKeys INT           NULL,
    AllUniqueKeys     INT           NULL,
    HashCols          INT           NULL,
    DupLogTables      INT           NULL,
    BatchCols         INT           NULL,
    ErrMsg            NVARCHAR(400) NULL
);

IF @IsSingleDb = 1
BEGIN
    INSERT INTO #DbList (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') IS NOT NULL
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB');
END

DECLARE @Tmpl NVARCHAR(MAX) = N'
INSERT INTO #Res (DbName, UserTables, DedupModules, StagingUniqueKeys, AllUniqueKeys, HashCols, DupLogTables, BatchCols)
SELECT
    N''{DBLIT}'',
    (SELECT COUNT(*)
       FROM {P}sys.tables AS t
      WHERE t.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM {P}sys.sql_modules AS m
       INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
      WHERE o.is_ms_shipped = 0
        AND ( m.definition LIKE N''%dedup%''
           OR m.definition LIKE N''%duplicate%''
           OR m.definition LIKE N''%HASHBYTES%''
           OR (m.definition LIKE N''%ROW_NUMBER%'' AND m.definition LIKE N''%PARTITION BY%'')
           OR (m.definition LIKE N''%MERGE%''      AND m.definition LIKE N''%WHEN NOT MATCHED%'')
           OR (m.definition LIKE N''%GROUP BY%''   AND m.definition LIKE N''%HAVING%COUNT%'') )),
    (SELECT COUNT(DISTINCT i.object_id)
       FROM {P}sys.indexes AS i
       INNER JOIN {P}sys.tables  AS t ON t.object_id = i.object_id
       INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
      WHERE i.is_unique = 1
        AND i.type IN (1, 2)
        AND t.is_ms_shipped = 0
        AND ( t.name LIKE N''%stag%''   OR t.name LIKE N''%land%''    OR t.name LIKE N''%raw%''
           OR t.name LIKE N''%import%'' OR t.name LIKE N''%inbound%'' OR t.name LIKE N''%ingest%''
           OR t.name LIKE N''%bronze%'' OR t.name LIKE N''%load%''    OR t.name LIKE N''%[_]src%''
           OR s.name LIKE N''%stag%''   OR s.name LIKE N''%land%''    OR s.name LIKE N''%raw%''
           OR s.name LIKE N''%import%'' OR s.name LIKE N''%ingest%''  OR s.name LIKE N''%bronze%'' )),
    (SELECT COUNT(DISTINCT i.object_id)
       FROM {P}sys.indexes AS i
       INNER JOIN {P}sys.tables AS t ON t.object_id = i.object_id
      WHERE i.is_unique = 1
        AND i.type IN (1, 2)
        AND t.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM {P}sys.columns AS c
       INNER JOIN {P}sys.tables AS t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0
        AND ( c.name LIKE N''%hash%''      OR c.name LIKE N''%checksum%''
           OR c.name LIKE N''%dedup%''     OR c.name LIKE N''%duplicate%''
           OR c.name LIKE N''%dup[_]%''    OR c.name LIKE N''%isdup%'' )),
    (SELECT COUNT(*)
       FROM {P}sys.tables AS t
       INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
      WHERE t.is_ms_shipped = 0
        AND ( t.name LIKE N''%dedup%''       OR t.name LIKE N''%duplicate%''
           OR t.name LIKE N''%reject%''      OR t.name LIKE N''%quarantine%''
           OR t.name LIKE N''%dataquality%'' OR t.name LIKE N''%data[_]quality%''
           OR t.name LIKE N''%dq[_]%''       OR s.name LIKE N''%quality%'' )),
    (SELECT COUNT(*)
       FROM {P}sys.columns AS c
       INNER JOIN {P}sys.tables AS t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0
        AND ( c.name LIKE N''%batch%''        OR c.name LIKE N''%load[_]id%''
           OR c.name LIKE N''%loadid%''       OR c.name LIKE N''%run[_]id%''
           OR c.name LIKE N''%runid%''        OR c.name LIKE N''%source[_]file%''
           OR c.name LIKE N''%file[_]id%''    OR c.name LIKE N''%load[_]date%''
           OR c.name LIKE N''%loaddate%''     OR c.name LIKE N''%ingest%''
           OR c.name LIKE N''%extract[_]date%'' ));';

DECLARE @Db SYSNAME, @Prefix NVARCHAR(300), @Sql NVARCHAR(MAX);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #DbList ORDER BY DbName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Prefix = CASE WHEN @IsSingleDb = 1 THEN N'' ELSE QUOTENAME(@Db) + N'.' END;

        SET @Sql = REPLACE(REPLACE(@Tmpl, N'{P}', @Prefix), N'{DBLIT}', REPLACE(@Db, N'''', N''''''));

        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #Res (DbName, ErrMsg) VALUES (@Db, LEFT(ERROR_MESSAGE(), 400));
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

SELECT
    r.DbName,
    r.UserTables,
    r.DedupModules,
    r.StagingUniqueKeys,
    r.AllUniqueKeys,
    r.HashCols,
    r.DupLogTables,
    r.BatchCols,
    Tier = CASE
             WHEN r.DedupModules > 0
                  AND r.BatchCols > 0
                  AND (r.StagingUniqueKeys > 0 OR r.HashCols > 0 OR r.DupLogTables > 0) THEN 3
             WHEN (r.DedupModules > 0 OR r.StagingUniqueKeys > 0)
                  AND r.BatchCols > 0 THEN 2
             WHEN r.DedupModules > 0 OR r.StagingUniqueKeys > 0 OR r.AllUniqueKeys > 0
                  OR r.HashCols > 0 OR r.DupLogTables > 0 THEN 1
             ELSE 0
           END
INTO #Tier
FROM #Res AS r
WHERE r.ErrMsg IS NULL
  AND ISNULL(r.UserTables, 0) > 0;

DECLARE @Scoped INT, @MinTier INT, @T3 INT, @T2 INT, @T1 INT, @T0 INT, @ErrCount INT, @Attempted INT;

SELECT @Attempted = COUNT(*) FROM #DbList;
SELECT @ErrCount  = COUNT(*) FROM #Res WHERE ErrMsg IS NOT NULL;

SELECT
    @Scoped  = COUNT(*),
    @MinTier = MIN(Tier),
    @T3 = SUM(CASE WHEN Tier = 3 THEN 1 ELSE 0 END),
    @T2 = SUM(CASE WHEN Tier = 2 THEN 1 ELSE 0 END),
    @T1 = SUM(CASE WHEN Tier = 1 THEN 1 ELSE 0 END),
    @T0 = SUM(CASE WHEN Tier = 0 THEN 1 ELSE 0 END)
FROM #Tier;

SET @Scoped   = ISNULL(@Scoped, 0);
SET @ErrCount = ISNULL(@ErrCount, 0);
SET @T3 = ISNULL(@T3, 0);
SET @T2 = ISNULL(@T2, 0);
SET @T1 = ISNULL(@T1, 0);
SET @T0 = ISNULL(@T0, 0);

DECLARE @Score INT, @Result NVARCHAR(20);

IF @Scoped = 0
BEGIN
    SET @Score = 0;
    SET @Result = N'NeedsReview';
END
ELSE
BEGIN
    SET @Score = ISNULL(@MinTier, 0);

    IF @ErrCount > 0 AND @Score > 2 SET @Score = 2;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                       WHEN @Score = 0 THEN N'Fail'
                       ELSE N'NeedsReview' END;
END

DECLARE @DbQueried NVARCHAR(MAX) =
    STUFF((SELECT N', ' + r.DbName
             FROM #Res AS r
            WHERE r.ErrMsg IS NULL
            ORDER BY r.DbName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Detail NVARCHAR(MAX) =
    STUFF((SELECT TOP (15) N'; ' + t.DbName
                  + N' [tier=' + CONVERT(NVARCHAR(10), t.Tier)
                  + N', dedupLogic=' + CONVERT(NVARCHAR(10), t.DedupModules)
                  + N', stagingUniqueKeys=' + CONVERT(NVARCHAR(10), t.StagingUniqueKeys)
                  + N', anyUniqueKeys=' + CONVERT(NVARCHAR(10), t.AllUniqueKeys)
                  + N', hashCols=' + CONVERT(NVARCHAR(10), t.HashCols)
                  + N', dupLogTables=' + CONVERT(NVARCHAR(10), t.DupLogTables)
                  + N', batchCols=' + CONVERT(NVARCHAR(10), t.BatchCols) + N']'
             FROM #Tier AS t
            ORDER BY t.Tier ASC, t.DbName ASC
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Errors NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N'; ' + r.DbName + N': ' + ISNULL(r.ErrMsg, N'unknown error')
             FROM #Res AS r
            WHERE r.ErrMsg IS NOT NULL
            ORDER BY r.DbName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Finding NVARCHAR(MAX) =
    N'Scanned ' + CONVERT(NVARCHAR(10), @Attempted) + N' database(s); '
  + CONVERT(NVARCHAR(10), @Scoped) + N' in scope (user tables present). '
  + N'Cross-batch duplicate-detection evidence by tier: tier3(dedup logic + batch identity + key/hash/reject artifact)='
  + CONVERT(NVARCHAR(10), @T3)
  + N', tier2(dedup logic or staging unique key + batch identity)=' + CONVERT(NVARCHAR(10), @T2)
  + N', tier1(weak/partial evidence only)=' + CONVERT(NVARCHAR(10), @T1)
  + N', tier0(no evidence)=' + CONVERT(NVARCHAR(10), @T0) + N'. '
  + CASE WHEN @Scoped = 0
         THEN N'No in-scope user database with user tables was available, so cross-batch duplicate detection could not be assessed automatically. '
         ELSE N'Lowest tier observed drives the score. Per-database detail (worst first): ' + ISNULL(@Detail, N'none') + N'. '
    END
  + CASE WHEN @ErrCount > 0
         THEN N'WARNING: ' + CONVERT(NVARCHAR(10), @ErrCount) + N' database(s) could not be queried (' + ISNULL(@Errors, N'') + N'); score capped at 2. '
         ELSE N''
    END
  + N'This is a metadata proxy check: it evidences the presence of duplicate-detection artifacts and batch identity, and manual confirmation is advised that the dedup keys actually span batches rather than only the current load.';

SELECT
    @Result                            AS Result,
    @Score                             AS Score,
    ISNULL(@DbQueried, N'None')        AS DatabaseQueried,
    @Finding                           AS Finding;

IF OBJECT_ID('tempdb..#Tier')   IS NOT NULL DROP TABLE #Tier;
IF OBJECT_ID('tempdb..#Res')    IS NOT NULL DROP TABLE #Res;
IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;