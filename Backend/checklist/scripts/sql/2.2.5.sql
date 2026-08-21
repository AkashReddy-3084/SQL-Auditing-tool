/* ============================================================================
   Checklist Item : 2.2.5 - Insert/Update/Delete operations handled correctly
                            (MERGE or equivalent)
   Area           : 2.2 Data Integration & ETL
   Scope          : DATABASE
   Read-only      : Yes. Catalog views only; no user data or schema is touched.

   What it does
   ------------
   For every accessible user database it reads sys.sql_modules for stored
   procedures and triggers and buckets every module that adds rows by the
   row-reconciliation pattern it uses:
       1 = MERGE     : a MERGE statement with WHEN MATCHED branches
       2 = Upsert    : adds new rows and also revises existing ones
       3 = Reload    : clears the target then reloads it in full
       4 = Add-only  : appends rows and never reconciles what is already there
   Bucket 4 is the failure mode this item targets: repeated runs duplicate rows
   and retired source records are never retired downstream.

   Limitations
   -----------
   Classification is keyword based over module text. Encrypted modules expose no
   definition and are skipped. Loads executed outside the engine (SSIS, ADF,
   Databricks) leave no module text and cannot be evidenced here.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

/* Azure SQL Database / Synapse cannot reach other databases from this session. */
DECLARE @SingleDbMode bit = CASE WHEN @EngineEdition IN (5, 6, 11) THEN 1 ELSE 0 END;

CREATE TABLE #Dbs
(
    DatabaseName sysname       NOT NULL,
    DbPrefix     nvarchar(300) NOT NULL
);

CREATE TABLE #DbResults
(
    DatabaseName  sysname       NOT NULL,
    LoadModules   int           NULL,
    MergeModules  int           NULL,
    UpsertModules int           NULL,
    ReloadModules int           NULL,
    BlindModules  int           NULL,
    ErrorMessage  nvarchar(400) NULL
);

IF @SingleDbMode = 1
    INSERT INTO #Dbs (DatabaseName, DbPrefix)
    SELECT DB_NAME(), N'';
ELSE
    INSERT INTO #Dbs (DatabaseName, DbPrefix)
    SELECT d.name, QUOTENAME(d.name) + N'.'
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.user_access = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @pMerge   nvarchar(60) = N'%MERGE%';
DECLARE @pMatched nvarchar(60) = N'%WHEN MATCHED%';
DECLARE @pIns     nvarchar(60) = N'%INSERT%';
DECLARE @pUpd     nvarchar(60) = N'%UPDATE%';
DECLARE @pDel     nvarchar(60) = N'%DELETE%';
DECLARE @pTrunc   nvarchar(60) = N'%TRUNCATE%';

DECLARE @ParamDef nvarchar(1000) =
    N'@dbn sysname, @pMerge nvarchar(60), @pMatched nvarchar(60), @pIns nvarchar(60), @pUpd nvarchar(60), @pDel nvarchar(60), @pTrunc nvarchar(60)';

DECLARE @SqlHead nvarchar(max) = N'
SELECT @dbn AS DatabaseName,
       COUNT(*) AS LoadModules,
       SUM(CASE WHEN c.Bucket = 1 THEN 1 ELSE 0 END) AS MergeModules,
       SUM(CASE WHEN c.Bucket = 2 THEN 1 ELSE 0 END) AS UpsertModules,
       SUM(CASE WHEN c.Bucket = 3 THEN 1 ELSE 0 END) AS ReloadModules,
       SUM(CASE WHEN c.Bucket = 4 THEN 1 ELSE 0 END) AS BlindModules,
       CAST(NULL AS nvarchar(400)) AS ErrorMessage
FROM (
    SELECT CASE
               WHEN d.Def LIKE @pMerge AND d.Def LIKE @pMatched THEN 1
               WHEN d.Def LIKE @pUpd THEN 2
               WHEN d.Def LIKE @pTrunc OR d.Def LIKE @pDel THEN 3
               ELSE 4
           END AS Bucket
    FROM (
        SELECT UPPER(REPLACE(REPLACE(m.definition, CHAR(13), N'' ''), CHAR(10), N'' '')) AS Def
        FROM ';

DECLARE @SqlMid nvarchar(max) = N'sys.sql_modules AS m
        INNER JOIN ';

DECLARE @SqlTail nvarchar(max) = N'sys.objects AS o
            ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'', ''TR'')
          AND m.definition IS NOT NULL
    ) AS d
    WHERE d.Def LIKE @pIns OR d.Def LIKE @pMerge
) AS c;';

DECLARE @DbName sysname;
DECLARE @DbPrefix nvarchar(300);
DECLARE @Sql nvarchar(max);

DECLARE DbCur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, DbPrefix FROM #Dbs ORDER BY DatabaseName;

OPEN DbCur;
FETCH NEXT FROM DbCur INTO @DbName, @DbPrefix;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = @SqlHead + @DbPrefix + @SqlMid + @DbPrefix + @SqlTail;

        INSERT INTO #DbResults
            (DatabaseName, LoadModules, MergeModules, UpsertModules, ReloadModules, BlindModules, ErrorMessage)
        EXEC sp_executesql @Sql, @ParamDef,
             @dbn = @DbName, @pMerge = @pMerge, @pMatched = @pMatched,
             @pIns = @pIns, @pUpd = @pUpd, @pDel = @pDel, @pTrunc = @pTrunc;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults
            (DatabaseName, LoadModules, MergeModules, UpsertModules, ReloadModules, BlindModules, ErrorMessage)
        SELECT @DbName, NULL, NULL, NULL, NULL, NULL, LEFT(ERROR_MESSAGE(), 400);
    END CATCH

    FETCH NEXT FROM DbCur INTO @DbName, @DbPrefix;
END

CLOSE DbCur;
DEALLOCATE DbCur;

DECLARE @TotalDbs int, @ErrorDbs int, @ScoredDbs int;
DECLARE @TotLoad int, @TotSafe int, @TotBlind int;
DECLARE @MinScore int, @WorstDb sysname;
DECLARE @DbList nvarchar(max), @Detail nvarchar(max);
DECLARE @Score int, @Result nvarchar(20), @Finding nvarchar(max);

SELECT @TotalDbs  = COUNT(*),
       @ErrorDbs  = SUM(CASE WHEN r.ErrorMessage IS NOT NULL THEN 1 ELSE 0 END),
       @ScoredDbs = SUM(CASE WHEN r.ErrorMessage IS NULL AND ISNULL(r.LoadModules, 0) > 0 THEN 1 ELSE 0 END),
       @TotLoad   = SUM(CASE WHEN r.ErrorMessage IS NULL THEN ISNULL(r.LoadModules, 0) ELSE 0 END),
       @TotSafe   = SUM(CASE WHEN r.ErrorMessage IS NULL
                             THEN ISNULL(r.MergeModules, 0) + ISNULL(r.UpsertModules, 0) + ISNULL(r.ReloadModules, 0)
                             ELSE 0 END),
       @TotBlind  = SUM(CASE WHEN r.ErrorMessage IS NULL THEN ISNULL(r.BlindModules, 0) ELSE 0 END)
FROM #DbResults AS r;

SELECT @MinScore = MIN(v.DbScore)
FROM (
    SELECT CASE
               WHEN (r.MergeModules + r.UpsertModules + r.ReloadModules) * 100 / r.LoadModules >= 90 THEN 3
               WHEN (r.MergeModules + r.UpsertModules + r.ReloadModules) * 100 / r.LoadModules >= 70 THEN 2
               WHEN (r.MergeModules + r.UpsertModules + r.ReloadModules) * 100 / r.LoadModules >= 40 THEN 1
               ELSE 0
           END AS DbScore
    FROM #DbResults AS r
    WHERE r.ErrorMessage IS NULL
      AND ISNULL(r.LoadModules, 0) > 0
) AS v;

SELECT TOP (1) @WorstDb = r.DatabaseName
FROM #DbResults AS r
WHERE r.ErrorMessage IS NULL
  AND ISNULL(r.LoadModules, 0) > 0
ORDER BY (r.MergeModules + r.UpsertModules + r.ReloadModules) * 100 / r.LoadModules ASC,
         r.BlindModules DESC,
         r.DatabaseName ASC;

SELECT @DbList = STUFF((
    SELECT N', ' + r.DatabaseName
    FROM #DbResults AS r
    ORDER BY r.DatabaseName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @Detail = STUFF((
    SELECT N'; ' + x.Txt
    FROM (
        SELECT TOP (5)
               r.DatabaseName + N' [' + CONVERT(nvarchar(20), r.LoadModules) + N' row-adding modules, '
                   + CONVERT(nvarchar(20), r.MergeModules + r.UpsertModules + r.ReloadModules) + N' reconciled, '
                   + CONVERT(nvarchar(20), r.BlindModules) + N' add-only]' AS Txt,
               (r.MergeModules + r.UpsertModules + r.ReloadModules) * 100 / r.LoadModules AS Pct,
               r.DatabaseName AS Nm
        FROM #DbResults AS r
        WHERE r.ErrorMessage IS NULL
          AND ISNULL(r.LoadModules, 0) > 0
        ORDER BY Pct ASC, r.DatabaseName ASC
    ) AS x
    ORDER BY x.Pct ASC, x.Nm ASC
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF ISNULL(@TotalDbs, 0) = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No accessible user database was found on this instance, so no row-reconciliation logic could be inspected.';
END
ELSE IF ISNULL(@ScoredDbs, 0) = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Across ' + CONVERT(nvarchar(20), @TotalDbs)
        + N' accessible user database(s) no stored procedure or trigger adds rows to tables'
        + CASE WHEN ISNULL(@ErrorDbs, 0) > 0
               THEN N' (' + CONVERT(nvarchar(20), @ErrorDbs) + N' database(s) could not be read)'
               ELSE N'' END
        + N'. Load logic therefore runs outside the engine (for example SSIS, ADF or Databricks) and the control cannot be evidenced from catalog metadata.';
END
ELSE
BEGIN
    SET @Score = @MinScore;
    SET @Finding = N'Inspected ' + CONVERT(nvarchar(20), @ScoredDbs) + N' of '
        + CONVERT(nvarchar(20), @TotalDbs) + N' accessible user database(s). '
        + CONVERT(nvarchar(20), @TotLoad) + N' stored procedure(s)/trigger(s) add rows, of which '
        + CONVERT(nvarchar(20), @TotSafe) + N' reconcile rows that already exist and '
        + CONVERT(nvarchar(20), @TotBlind) + N' append only. Weakest database: '
        + ISNULL(@WorstDb, N'n/a') + N'. Detail (worst first): ' + ISNULL(@Detail, N'none')
        + CASE WHEN ISNULL(@ErrorDbs, 0) > 0
               THEN N'. ' + CONVERT(nvarchar(20), @ErrorDbs) + N' database(s) could not be read and were excluded from scoring.'
               ELSE N'.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result                  AS Result,
       @Score                   AS Score,
       ISNULL(@DbList, N'None') AS DatabaseQueried,
       @Finding                 AS Finding;