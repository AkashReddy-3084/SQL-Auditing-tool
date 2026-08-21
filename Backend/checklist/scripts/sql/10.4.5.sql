/*
    Checklist Item : 10.4.5 - Log/rowcount reconciliation captured per ETL run
    Area           : Monitoring & Observability
    Scope          : DATABASE
    Access         : STRICTLY READ-ONLY (system catalog / DMV reads and #temp tables only)
    Output         : Result, Score, DatabaseQueried, Finding
*/

SET NOCOUNT ON;

DECLARE @IsAzureSqlDb BIT =
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Databases')    IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#Candidates')   IS NOT NULL DROP TABLE #Candidates;
IF OBJECT_ID('tempdb..#RowCounts')    IS NOT NULL DROP TABLE #RowCounts;
IF OBJECT_ID('tempdb..#Ssis')         IS NOT NULL DROP TABLE #Ssis;
IF OBJECT_ID('tempdb..#Inaccessible') IS NOT NULL DROP TABLE #Inaccessible;
IF OBJECT_ID('tempdb..#Eval')         IS NOT NULL DROP TABLE #Eval;

CREATE TABLE #Databases
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

CREATE TABLE #Candidates
(
    DatabaseName        SYSNAME NOT NULL,
    SchemaName          SYSNAME NOT NULL,
    TableName           SYSNAME NOT NULL,
    ObjectId            INT     NOT NULL,
    HasRowCountCol      BIT     NOT NULL,
    HasRunIdCol         BIT     NOT NULL,
    HasTimeCol          BIT     NOT NULL,
    HasSrcTgtPair       BIT     NOT NULL,
    NameLooksLikeEtlLog BIT     NOT NULL
);

CREATE TABLE #RowCounts
(
    DatabaseName SYSNAME NOT NULL,
    ObjectId     INT     NOT NULL,
    RowCnt       BIGINT  NULL
);

CREATE TABLE #Ssis
(
    DatabaseName   SYSNAME NOT NULL,
    ExecutionCount BIGINT  NULL,
    RowStatCount   BIGINT  NULL
);

CREATE TABLE #Inaccessible
(
    DatabaseName SYSNAME        NOT NULL,
    ErrorMessage NVARCHAR(2048) NULL
);

CREATE TABLE #Eval
(
    DatabaseName   SYSNAME     NOT NULL,
    SchemaName     SYSNAME     NOT NULL,
    TableName      SYSNAME     NOT NULL,
    RowCnt         BIGINT      NULL,
    Classification VARCHAR(10) NOT NULL
);

/* ---------- database inventory ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

/* ---------- naming predicates injected into the per-database probe ---------- */
DECLARE @PredRowCount NVARCHAR(MAX) =
    N'(LOWER(c.name) LIKE ''%rowcount%'' OR LOWER(c.name) LIKE ''%row[_]count%'' OR LOWER(c.name) LIKE ''%rows[_]%'''
  + N' OR LOWER(c.name) LIKE ''%[_]rows%'' OR LOWER(c.name) LIKE ''%recordcount%'' OR LOWER(c.name) LIKE ''%record[_]count%'''
  + N' OR LOWER(c.name) LIKE ''%reccount%'' OR LOWER(c.name) LIKE ''%reconcil%'' OR LOWER(c.name) LIKE ''%rowsprocessed%'''
  + N' OR LOWER(c.name) LIKE ''%rowsinserted%'' OR LOWER(c.name) LIKE ''%rowsread%'' OR LOWER(c.name) LIKE ''%rowswritten%'''
  + N' OR LOWER(c.name) LIKE ''%rowsaffected%'' OR LOWER(c.name) LIKE ''%rowsrejected%'')';

DECLARE @PredRunId NVARCHAR(MAX) =
    N'(LOWER(c.name) LIKE ''%runid%'' OR LOWER(c.name) LIKE ''%run[_]id%'' OR LOWER(c.name) LIKE ''%runkey%'''
  + N' OR LOWER(c.name) LIKE ''%batchid%'' OR LOWER(c.name) LIKE ''%batch[_]id%'' OR LOWER(c.name) LIKE ''%batchkey%'''
  + N' OR LOWER(c.name) LIKE ''%executionid%'' OR LOWER(c.name) LIKE ''%execution[_]id%'''
  + N' OR LOWER(c.name) LIKE ''%loadid%'' OR LOWER(c.name) LIKE ''%load[_]id%'' OR LOWER(c.name) LIKE ''%loadkey%'''
  + N' OR LOWER(c.name) LIKE ''%packageid%'' OR LOWER(c.name) LIKE ''%package[_]id%'''
  + N' OR LOWER(c.name) LIKE ''%jobid%'' OR LOWER(c.name) LIKE ''%job[_]id%'''
  + N' OR LOWER(c.name) LIKE ''%processid%'' OR LOWER(c.name) LIKE ''%process[_]id%'''
  + N' OR LOWER(c.name) LIKE ''%etlid%'' OR LOWER(c.name) LIKE ''%etl[_]id%'''
  + N' OR LOWER(c.name) LIKE ''%sessionid%'' OR LOWER(c.name) LIKE ''%session[_]id%'')';

DECLARE @PredTime NVARCHAR(MAX) =
    N'(LOWER(c.name) LIKE ''%date%'' OR LOWER(c.name) LIKE ''%time%'' OR LOWER(c.name) LIKE ''%stamp%'')';

DECLARE @PredSrc NVARCHAR(MAX) =
    N'(LOWER(c.name) LIKE ''%source%'' OR LOWER(c.name) LIKE ''%src%'' OR LOWER(c.name) LIKE ''%extract%'')';

DECLARE @PredTgt NVARCHAR(MAX) =
    N'(LOWER(c.name) LIKE ''%target%'' OR LOWER(c.name) LIKE ''%tgt%'' OR LOWER(c.name) LIKE ''%dest%'' OR LOWER(c.name) LIKE ''%load%'')';

DECLARE @PredName NVARCHAR(MAX) =
    N'(LOWER(t.name) LIKE ''%etl%'' OR LOWER(t.name) LIKE ''%log%'' OR LOWER(t.name) LIKE ''%audit%'''
  + N' OR LOWER(t.name) LIKE ''%batch%'' OR LOWER(t.name) LIKE ''%load%'' OR LOWER(t.name) LIKE ''%run%'''
  + N' OR LOWER(t.name) LIKE ''%process%'' OR LOWER(t.name) LIKE ''%import%'' OR LOWER(t.name) LIKE ''%recon%'''
  + N' OR LOWER(t.name) LIKE ''%staging%'' OR LOWER(t.name) LIKE ''%control%'''
  + N' OR LOWER(s.name) LIKE ''%etl%'' OR LOWER(s.name) LIKE ''%audit%'' OR LOWER(s.name) LIKE ''%log%'')';

/* ---------- per-database probe ---------- */
DECLARE @DbName SYSNAME;
DECLARE @Prefix NVARCHAR(300);
DECLARE @Sql    NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

    BEGIN TRY
        SET @Sql =
            N'INSERT INTO #Candidates (DatabaseName, SchemaName, TableName, ObjectId, HasRowCountCol, HasRunIdCol, HasTimeCol, HasSrcTgtPair, NameLooksLikeEtlLog)' + NCHAR(13) +
            N'SELECT @db_in, s.name, t.name, t.object_id,' + NCHAR(13) +
            N'       MAX(CASE WHEN ' + @PredRowCount + N' THEN 1 ELSE 0 END),' + NCHAR(13) +
            N'       MAX(CASE WHEN ' + @PredRunId    + N' THEN 1 ELSE 0 END),' + NCHAR(13) +
            N'       MAX(CASE WHEN ' + @PredTime     + N' THEN 1 ELSE 0 END),' + NCHAR(13) +
            N'       CASE WHEN MAX(CASE WHEN ' + @PredSrc + N' THEN 1 ELSE 0 END) = 1' + NCHAR(13) +
            N'             AND MAX(CASE WHEN ' + @PredTgt + N' THEN 1 ELSE 0 END) = 1 THEN 1 ELSE 0 END,' + NCHAR(13) +
            N'       MAX(CASE WHEN ' + @PredName + N' THEN 1 ELSE 0 END)' + NCHAR(13) +
            N'FROM ' + @Prefix + N'sys.tables AS t' + NCHAR(13) +
            N'INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id' + NCHAR(13) +
            N'INNER JOIN ' + @Prefix + N'sys.columns AS c ON c.object_id = t.object_id' + NCHAR(13) +
            N'WHERE t.is_ms_shipped = 0' + NCHAR(13) +
            N'GROUP BY s.name, t.name, t.object_id' + NCHAR(13) +
            N'HAVING MAX(CASE WHEN ' + @PredRowCount + N' THEN 1 ELSE 0 END) = 1;';

        EXEC sys.sp_executesql @Sql, N'@db_in SYSNAME', @db_in = @DbName;

        SET @Sql =
            N'INSERT INTO #RowCounts (DatabaseName, ObjectId, RowCnt)' + NCHAR(13) +
            N'SELECT @db_in, ps.object_id, SUM(ps.row_count)' + NCHAR(13) +
            N'FROM ' + @Prefix + N'sys.dm_db_partition_stats AS ps' + NCHAR(13) +
            N'WHERE ps.index_id IN (0, 1)' + NCHAR(13) +
            N'GROUP BY ps.object_id;';

        EXEC sys.sp_executesql @Sql, N'@db_in SYSNAME', @db_in = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #Inaccessible (DatabaseName, ErrorMessage)
        VALUES (@DbName, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    /* SSIS catalog is a first-class per-run row-count reconciliation store */
    IF @IsAzureSqlDb = 0
       AND OBJECT_ID(QUOTENAME(@DbName) + N'.internal.executions') IS NOT NULL
       AND OBJECT_ID(QUOTENAME(@DbName) + N'.internal.execution_data_statistics') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql =
                N'INSERT INTO #Ssis (DatabaseName, ExecutionCount, RowStatCount)' + NCHAR(13) +
                N'SELECT @db_in,' + NCHAR(13) +
                N'       (SELECT COUNT_BIG(*) FROM ' + @Prefix + N'internal.executions),' + NCHAR(13) +
                N'       (SELECT COUNT_BIG(*) FROM ' + @Prefix + N'internal.execution_data_statistics);';

            EXEC sys.sp_executesql @Sql, N'@db_in SYSNAME', @db_in = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #Inaccessible (DatabaseName, ErrorMessage)
            VALUES (@DbName, LEFT(ERROR_MESSAGE(), 2048));
        END CATCH
    END

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---------- classify ---------- */
INSERT INTO #Eval (DatabaseName, SchemaName, TableName, RowCnt, Classification)
SELECT cd.DatabaseName,
       cd.SchemaName,
       cd.TableName,
       ISNULL(rc.RowCnt, 0),
       CASE
            WHEN cd.HasRowCountCol = 1
                 AND cd.HasRunIdCol = 1
                 AND (cd.HasTimeCol = 1 OR cd.HasSrcTgtPair = 1)
                 AND ISNULL(rc.RowCnt, 0) > 0
                 THEN 'STRONG'
            ELSE 'PARTIAL'
       END
FROM #Candidates AS cd
LEFT JOIN #RowCounts AS rc
       ON rc.DatabaseName = cd.DatabaseName
      AND rc.ObjectId     = cd.ObjectId
WHERE cd.HasRowCountCol = 1
  AND (cd.HasRunIdCol = 1 OR cd.NameLooksLikeEtlLog = 1 OR cd.HasSrcTgtPair = 1);

DECLARE @DbScanned      INT = (SELECT COUNT(*) FROM #Databases);
DECLARE @DbInaccessible INT = (SELECT COUNT(DISTINCT DatabaseName) FROM #Inaccessible);
DECLARE @StrongCount    INT = (SELECT COUNT(*) FROM #Eval WHERE Classification = 'STRONG');
DECLARE @PartialCount   INT = (SELECT COUNT(*) FROM #Eval WHERE Classification = 'PARTIAL');
DECLARE @SsisStrong     INT = (SELECT COUNT(*) FROM #Ssis WHERE ISNULL(ExecutionCount, 0) > 0 AND ISNULL(RowStatCount, 0) > 0);
DECLARE @SsisPartial    INT = (SELECT COUNT(*) FROM #Ssis WHERE ISNULL(ExecutionCount, 0) > 0 AND ISNULL(RowStatCount, 0) = 0);

DECLARE @Score  INT;
DECLARE @Result NVARCHAR(20);

SET @Score =
    CASE
        WHEN @StrongCount > 0 OR @SsisStrong > 0 THEN 3
        WHEN @PartialCount > 0 OR @SsisPartial > 0 THEN 2
        ELSE 0
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* ---------- reporting strings ---------- */
DECLARE @EvidenceDbs NVARCHAR(MAX) =
    STUFF((SELECT N', ' + x.DatabaseName
           FROM (SELECT DISTINCT DatabaseName FROM #Eval
                 UNION
                 SELECT DISTINCT DatabaseName FROM #Ssis WHERE ISNULL(ExecutionCount, 0) > 0) AS x
           ORDER BY x.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @ScannedDbs NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Databases AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @Examples NVARCHAR(MAX) =
    STUFF((SELECT N'; ' + e.DatabaseName + N'.' + e.SchemaName + N'.' + e.TableName
                + N' (' + e.Classification + N', rows=' + CAST(ISNULL(e.RowCnt, 0) AS NVARCHAR(20)) + N')'
           FROM (SELECT TOP (5) DatabaseName, SchemaName, TableName, RowCnt, Classification
                 FROM #Eval
                 ORDER BY CASE WHEN Classification = 'STRONG' THEN 0 ELSE 1 END, RowCnt DESC, DatabaseName, SchemaName, TableName) AS e
           ORDER BY CASE WHEN e.Classification = 'STRONG' THEN 0 ELSE 1 END, e.RowCnt DESC
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @SsisText NVARCHAR(400) =
    CASE
        WHEN @SsisStrong > 0 THEN N' SSIS catalog holds package executions with execution_data_statistics row counts.'
        WHEN @SsisPartial > 0 THEN N' SSIS catalog holds package executions but no execution_data_statistics rows (row-count logging level not enabled).'
        ELSE N''
    END;

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    LEFT(CASE
            WHEN @DbScanned = 0 THEN N'None'
            WHEN @EvidenceDbs IS NOT NULL THEN @EvidenceDbs
            ELSE ISNULL(@ScannedDbs, N'None')
         END, 3000);

DECLARE @Finding NVARCHAR(MAX) =
    CASE
        WHEN @DbScanned = 0
            THEN N'No accessible online user database was found, so ETL row-count reconciliation logging could not be assessed.'
        WHEN @Score = 3
            THEN N'ETL run logging with row-count reconciliation is present and populated. Scanned ' + CAST(@DbScanned AS NVARCHAR(20))
               + N' database(s); found ' + CAST(@StrongCount AS NVARCHAR(20))
               + N' populated log table(s) carrying a row-count measure together with a run/batch identifier and a timestamp or source/target count pair, plus '
               + CAST(@PartialCount AS NVARCHAR(20)) + N' weaker candidate(s).' + @SsisText
               + N' Examples: ' + ISNULL(@Examples, N'n/a') + N'.'
        WHEN @Score = 2
            THEN N'Row-count logging structures exist but do not fully demonstrate per-run reconciliation. Scanned ' + CAST(@DbScanned AS NVARCHAR(20))
               + N' database(s); found ' + CAST(@PartialCount AS NVARCHAR(20))
               + N' candidate table(s) with a row-count column but either no populated rows or no run/batch identifier and timestamp pairing, and 0 fully qualifying log table(s).'
               + @SsisText + N' Examples: ' + ISNULL(@Examples, N'n/a') + N'.'
        ELSE N'No ETL row-count reconciliation logging was found. Scanned ' + CAST(@DbScanned AS NVARCHAR(20))
               + N' database(s) and found no user table exposing a row-count/reconciliation column alongside a run, batch or execution identifier, and no populated SSIS catalog execution statistics.'
    END
    + CASE WHEN @DbInaccessible > 0
           THEN N' Note: ' + CAST(@DbInaccessible AS NVARCHAR(20)) + N' database(s) could not be inspected due to permissions or availability and are excluded from this result.'
           ELSE N'' END;

SELECT
    @Result              AS Result,
    @Score               AS Score,
    @DatabaseQueried     AS DatabaseQueried,
    LEFT(@Finding, 4000) AS Finding;