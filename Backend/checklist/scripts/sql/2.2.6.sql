/*  Checklist 2.2.6 - Late-arriving / out-of-order data handled without corruption
    Read-only proxy check: catalog metadata and module text only.                */
SET NOCOUNT ON;

DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVer INT = ISNULL(TRY_CONVERT(INT, PARSENAME(CONVERT(NVARCHAR(50), SERVERPROPERTY('ProductVersion')), 4)), 0);
-- temporal_type exists from SQL Server 2016; Azure SQL Database always reports an older-looking version
DECLARE @SupportsTemporal BIT = CASE WHEN @IsAzureDb = 1 OR @MajorVer >= 13 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName SYSNAME NOT NULL, HasEtl INT NOT NULL, Ordering INT NOT NULL, Watermark INT NOT NULL,
    EventVsLoad INT NOT NULL, History INT NOT NULL, Idempotent INT NOT NULL,
    DbScore INT NOT NULL, Note NVARCHAR(400) NULL);
CREATE TABLE #Targets (DbName SYSNAME NOT NULL);

IF @IsAzureDb = 1
    INSERT INTO #Targets (DbName) SELECT DB_NAME();
ELSE
    INSERT INTO #Targets (DbName)
    SELECT d.name FROM sys.databases d
    WHERE d.database_id > 4 AND d.state = 0 AND d.is_read_only = 0
      AND d.source_database_id IS NULL AND HAS_DBACCESS(d.name) = 1
      AND d.name NOT IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution');

DECLARE @DbName SYSNAME, @P NVARCHAR(300), @sql NVARCHAR(MAX), @TemporalPred NVARCHAR(400);
DECLARE @HasEtl INT, @Ordering INT, @Watermark INT, @EventVsLoad INT, @History INT, @Idempotent INT;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #Targets ORDER BY DbName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @HasEtl = 0, @Ordering = 0, @Watermark = 0, @EventVsLoad = 0, @History = 0, @Idempotent = 0;
    SET @P = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;
    SET @TemporalPred = CASE WHEN @SupportsTemporal = 1
        THEN N'EXISTS (SELECT 1 FROM ' + @P + N'sys.tables t4 WHERE t4.temporal_type = 2) OR '
        ELSE N'' END;

    SET @sql = N'
SELECT
 @pHasEtl = CASE WHEN EXISTS (SELECT 1 FROM ' + @P + N'sys.tables t
        WHERE LOWER(t.name) LIKE N''stg%'' OR LOWER(t.name) LIKE N''%staging%''
           OR LOWER(t.name) LIKE N''fact%'' OR LOWER(t.name) LIKE N''dim%''
           OR LOWER(t.name) LIKE N''%landing%'' OR LOWER(t.name) LIKE N''raw[_]%''
           OR LOWER(t.name) LIKE N''ods[_]%'')
     OR EXISTS (SELECT 1 FROM ' + @P + N'sys.sql_modules m
        WHERE m.definition LIKE N''%WHEN MATCHED%'' OR m.definition LIKE N''%OPENROWSET%''
           OR m.definition LIKE N''%ROW_NUMBER%'') THEN 1 ELSE 0 END,
 @pOrdering = CASE WHEN EXISTS (SELECT 1 FROM ' + @P + N'sys.sql_modules m
        WHERE m.definition LIKE N''%ROW_NUMBER%PARTITION BY%ORDER BY%''
           OR m.definition LIKE N''%WHEN MATCHED AND%'') THEN 1 ELSE 0 END,
 @pWatermark = CASE WHEN EXISTS (SELECT 1 FROM ' + @P + N'sys.tables t
        WHERE LOWER(t.name) LIKE N''%watermark%'' OR LOWER(t.name) LIKE N''%load[_]control%''
           OR LOWER(t.name) LIKE N''%loadcontrol%'' OR LOWER(t.name) LIKE N''%etl[_]control%'')
     OR EXISTS (SELECT 1 FROM ' + @P + N'sys.columns c
        JOIN ' + @P + N'sys.tables t2 ON t2.object_id = c.object_id
        WHERE LOWER(c.name) LIKE N''%watermark%'' OR LOWER(c.name) LIKE N''%high[_]water%''
           OR LOWER(c.name) LIKE N''%highwater%'' OR LOWER(c.name) LIKE N''%last[_]load%''
           OR LOWER(c.name) LIKE N''%lastload%'' OR LOWER(c.name) LIKE N''%last[_]processed%''
           OR LOWER(c.name) LIKE N''%lastprocessed%'') THEN 1 ELSE 0 END,
 @pEventVsLoad = CASE WHEN EXISTS (SELECT 1 FROM ' + @P + N'sys.tables t3
        WHERE EXISTS (SELECT 1 FROM ' + @P + N'sys.columns ec WHERE ec.object_id = t3.object_id
              AND (LOWER(ec.name) LIKE N''%event[_]%time%'' OR LOWER(ec.name) LIKE N''%eventtime%''
                OR LOWER(ec.name) LIKE N''%eventdate%'' OR LOWER(ec.name) LIKE N''%sourcedate%''
                OR LOWER(ec.name) LIKE N''%source[_]date%'' OR LOWER(ec.name) LIKE N''%occurred%''
                OR LOWER(ec.name) LIKE N''%transactiondate%''))
          AND EXISTS (SELECT 1 FROM ' + @P + N'sys.columns lc WHERE lc.object_id = t3.object_id
              AND (LOWER(lc.name) LIKE N''%loaddate%'' OR LOWER(lc.name) LIKE N''%load[_]date%''
                OR LOWER(lc.name) LIKE N''%loadts%'' OR LOWER(lc.name) LIKE N''%ingest%''
                OR LOWER(lc.name) LIKE N''%inserted[_]at%'' OR LOWER(lc.name) LIKE N''%insertdate%''
                OR LOWER(lc.name) LIKE N''%processed[_]%'' OR LOWER(lc.name) LIKE N''%etl[_]%date%''))
        ) THEN 1 ELSE 0 END,
 @pHistory = CASE WHEN ' + @TemporalPred + N'EXISTS (SELECT 1 FROM ' + @P + N'sys.columns c2
        JOIN ' + @P + N'sys.tables t5 ON t5.object_id = c2.object_id
        WHERE LOWER(c2.name) IN (N''validfrom'', N''validto'', N''valid_from'', N''valid_to'',
              N''effectivefrom'', N''effectiveto'', N''effective_from'', N''effective_to'',
              N''rowiscurrent'', N''iscurrent'', N''is_current'')) THEN 1 ELSE 0 END,
 @pIdempotent = CASE WHEN EXISTS (SELECT 1 FROM ' + @P + N'sys.indexes i
        JOIN ' + @P + N'sys.tables t6 ON t6.object_id = i.object_id
        WHERE i.is_unique = 1 AND i.type IN (1, 2)
          AND (LOWER(t6.name) LIKE N''stg%'' OR LOWER(t6.name) LIKE N''%staging%''
            OR LOWER(t6.name) LIKE N''fact%'' OR LOWER(t6.name) LIKE N''%landing%''))
     OR EXISTS (SELECT 1 FROM ' + @P + N'sys.sql_modules m2
        WHERE m2.definition LIKE N''%WHEN NOT MATCHED%'') THEN 1 ELSE 0 END;';

    BEGIN TRY
        EXEC sp_executesql @sql,
             N'@pHasEtl INT OUTPUT, @pOrdering INT OUTPUT, @pWatermark INT OUTPUT,
               @pEventVsLoad INT OUTPUT, @pHistory INT OUTPUT, @pIdempotent INT OUTPUT',
             @pHasEtl = @HasEtl OUTPUT, @pOrdering = @Ordering OUTPUT, @pWatermark = @Watermark OUTPUT,
             @pEventVsLoad = @EventVsLoad OUTPUT, @pHistory = @History OUTPUT, @pIdempotent = @Idempotent OUTPUT;

        INSERT INTO #DbResults (DbName, HasEtl, Ordering, Watermark, EventVsLoad, History, Idempotent, DbScore, Note)
        SELECT @DbName, @HasEtl, @Ordering, @Watermark, @EventVsLoad, @History, @Idempotent,
               CASE WHEN @HasEtl = 0 THEN 3
                    WHEN @Ordering = 1 AND (@Ordering + @Watermark + @EventVsLoad + @History + @Idempotent) >= 3 THEN 3
                    WHEN (@Ordering + @Watermark + @EventVsLoad + @History + @Idempotent) >= 2 THEN 2
                    WHEN (@Ordering + @Watermark + @EventVsLoad + @History + @Idempotent) = 1 THEN 1
                    ELSE 0 END,
               CASE WHEN @HasEtl = 0 THEN N'No ETL/data-loading footprint detected' ELSE NULL END;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, HasEtl, Ordering, Watermark, EventVsLoad, History, Idempotent, DbScore, Note)
        SELECT @DbName, 0, 0, 0, 0, 0, 0, 3, N'Metadata not readable: ' + LEFT(ERROR_MESSAGE(), 300);
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END
CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @TotalDbs INT = ISNULL((SELECT COUNT(*) FROM #DbResults), 0);
DECLARE @EtlDbs INT = ISNULL((SELECT COUNT(*) FROM #DbResults WHERE HasEtl = 1), 0);
DECLARE @WeakDbs INT = ISNULL((SELECT COUNT(*) FROM #DbResults WHERE HasEtl = 1 AND DbScore <= 1), 0);
DECLARE @PartialDbs INT = ISNULL((SELECT COUNT(*) FROM #DbResults WHERE HasEtl = 1 AND DbScore = 2), 0);
DECLARE @OrderingDbs INT = ISNULL((SELECT COUNT(*) FROM #DbResults WHERE HasEtl = 1 AND Ordering = 1), 0);
DECLARE @WeakPct DECIMAL(9,2) = ISNULL(100.0 * @WeakDbs / NULLIF(@EtlDbs, 0), 0);

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);

SET @Score = CASE WHEN @EtlDbs = 0 THEN 3
                  WHEN @WeakDbs = 0 AND @PartialDbs = 0 THEN 3
                  WHEN @WeakPct < 5 THEN 2
                  WHEN @WeakPct < 25 THEN 1
                  ELSE 0 END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @WeakList NVARCHAR(MAX) = ISNULL(STUFF((SELECT N', ' + r.DbName FROM #DbResults r
        WHERE r.HasEtl = 1 AND r.DbScore <= 1 ORDER BY r.DbName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');
DECLARE @DatabaseQueried NVARCHAR(MAX) = ISNULL(STUFF((SELECT N', ' + r.DbName FROM #DbResults r
        ORDER BY r.DbName FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''),
        N'No accessible user databases');

DECLARE @Finding NVARCHAR(MAX) =
    N'Inspected ' + CONVERT(NVARCHAR(10), @TotalDbs) + N' database(s); '
  + CONVERT(NVARCHAR(10), @EtlDbs) + N' show an ETL/data-loading footprint. '
  + CASE WHEN @EtlDbs = 0
         THEN N'No staging/fact/landing structures or load logic were found, so late-arriving data handling is not exercised on this instance.'
         ELSE CONVERT(NVARCHAR(10), @OrderingDbs) + N' of them carry ordering/de-duplication logic, '
            + CONVERT(NVARCHAR(10), @PartialDbs) + N' have partial coverage and '
            + CONVERT(NVARCHAR(10), @WeakDbs) + N' (' + CONVERT(NVARCHAR(20), @WeakPct)
            + N'%) have one control or none. Databases with weak or absent late-arrival controls: ' + @WeakList + N'.'
    END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;