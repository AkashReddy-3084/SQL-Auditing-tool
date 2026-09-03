SET NOCOUNT ON;

DECLARE @SsisDbExists bit = 0;
DECLARE @PackageCount int = 0;
DECLARE @PackagesWithHandlers int = 0;
DECLARE @HandlerCount int = 0;
DECLARE @TryCatchModules int = 0;
DECLARE @EtlLikeModules int = 0;
DECLARE @EtlLikeWithTryCatch int = 0;
DECLARE @JobCount int = 0;
DECLARE @JobsWithFailureAction int = 0;
DECLARE @JobsWithNotifyFail int = 0;
DECLARE @EvidenceParts nvarchar(max) = N'';
DECLARE @Result varchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(max);
DECLARE @DatabaseQueried nvarchar(200);
DECLARE @db sysname;
DECLARE @sql nvarchar(max);
DECLARE @HasEtlSurface bit = 0;
DECLARE @StrongSsis bit = 0;
DECLARE @PartialSsis bit = 0;
DECLARE @StrongTsql bit = 0;
DECLARE @PartialTsql bit = 0;
DECLARE @StrongJobs bit = 0;
DECLARE @PartialJobs bit = 0;

IF DB_ID(N'SSISDB') IS NOT NULL
    SET @SsisDbExists = 1;

IF @SsisDbExists = 1
BEGIN
    BEGIN TRY
        IF OBJECT_ID(N'SSISDB.catalog.packages', N'V') IS NOT NULL
        BEGIN
            SELECT @PackageCount = COUNT(*)
            FROM SSISDB.catalog.packages;
        END

        IF OBJECT_ID(N'SSISDB.catalog.event_messages', N'V') IS NOT NULL
        BEGIN
            SELECT @HandlerCount = COUNT(*)
            FROM SSISDB.catalog.event_messages
            WHERE event_name IN (N'OnError', N'OnTaskFailed');

            SELECT @PackagesWithHandlers = COUNT(DISTINCT package_name)
            FROM SSISDB.catalog.event_messages
            WHERE event_name IN (N'OnError', N'OnTaskFailed')
              AND package_name IS NOT NULL;
        END
    END TRY
    BEGIN CATCH
        SET @PackageCount = ISNULL(@PackageCount, 0);
        SET @PackagesWithHandlers = ISNULL(@PackagesWithHandlers, 0);
        SET @HandlerCount = ISNULL(@HandlerCount, 0);
    END CATCH
END

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;
CREATE TABLE #ModuleStats (
    database_name sysname NOT NULL,
    etl_like_modules int NOT NULL,
    etl_like_with_trycatch int NOT NULL,
    trycatch_modules int NOT NULL
);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases d
    WHERE d.state = 0
      AND d.database_id > 4
      AND d.name NOT IN (N'SSISDB', N'distribution')
      AND HAS_DBACCESS(d.name) = 1;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    INSERT INTO #ModuleStats (database_name, etl_like_modules, etl_like_with_trycatch, trycatch_modules)
    SELECT
        @dbname,
        SUM(CASE WHEN (
                        o.name LIKE N''%ETL%'' OR o.name LIKE N''%Load%''
                     OR o.name LIKE N''%Extract%'' OR o.name LIKE N''%Stage%''
                     OR o.name LIKE N''%Staging%'' OR o.name LIKE N''%Import%''
                     OR o.name LIKE N''%Export%'' OR o.name LIKE N''%Ingest%''
                     OR s.name LIKE N''%etl%''
                     OR s.name LIKE N''%stage%''
                     OR s.name LIKE N''%staging%''
                  ) THEN 1 ELSE 0 END),
        SUM(CASE WHEN (
                        o.name LIKE N''%ETL%'' OR o.name LIKE N''%Load%''
                     OR o.name LIKE N''%Extract%'' OR o.name LIKE N''%Stage%''
                     OR o.name LIKE N''%Staging%'' OR o.name LIKE N''%Import%''
                     OR o.name LIKE N''%Export%'' OR o.name LIKE N''%Ingest%''
                     OR s.name LIKE N''%etl%''
                     OR s.name LIKE N''%stage%''
                     OR s.name LIKE N''%staging%''
                  )
                  AND UPPER(m.definition) LIKE N''%BEGIN TRY%''
                  AND UPPER(m.definition) LIKE N''%BEGIN CATCH%''
             THEN 1 ELSE 0 END),
        SUM(CASE WHEN m.definition IS NOT NULL
                  AND UPPER(m.definition) LIKE N''%BEGIN TRY%''
                  AND UPPER(m.definition) LIKE N''%BEGIN CATCH%''
             THEN 1 ELSE 0 END)
    FROM ' + QUOTENAME(@db) + N'.sys.objects o
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.sql_modules m ON m.object_id = o.object_id
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas s ON s.schema_id = o.schema_id
    WHERE o.type IN (N''P'', N''PC'', N''FN'', N''IF'', N''TF'', N''TR'')
      AND o.is_ms_shipped = 0;';

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@dbname sysname', @dbname = @db;
    END TRY
    BEGIN CATCH
        -- skip inaccessible database
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @db;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT
    @EtlLikeModules = ISNULL(SUM(etl_like_modules), 0),
    @EtlLikeWithTryCatch = ISNULL(SUM(etl_like_with_trycatch), 0),
    @TryCatchModules = ISNULL(SUM(trycatch_modules), 0)
FROM #ModuleStats;

IF OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1;

    SELECT @JobsWithFailureAction = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE j.enabled = 1
      AND s.on_fail_action IN (2, 4);

    SELECT @JobsWithNotifyFail = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (
            ISNULL(j.notify_level_email, 0) IN (2, 3)
            OR ISNULL(j.notify_level_eventlog, 0) IN (2, 3)
            OR ISNULL(j.notify_level_page, 0) IN (2, 3)
          );
END

IF @SsisDbExists = 1
    SET @EvidenceParts = @EvidenceParts + N'SSISDB packages=' + CAST(@PackageCount AS nvarchar(20))
        + N'; packages_with_OnError_or_OnTaskFailed_events=' + CAST(@PackagesWithHandlers AS nvarchar(20))
        + N'; onerror_event_rows=' + CAST(@HandlerCount AS nvarchar(20)) + N'. ';
ELSE
    SET @EvidenceParts = @EvidenceParts + N'SSISDB not present. ';

SET @EvidenceParts = @EvidenceParts
    + N'ETL-like modules=' + CAST(@EtlLikeModules AS nvarchar(20))
    + N'; ETL-like with TRY/CATCH=' + CAST(@EtlLikeWithTryCatch AS nvarchar(20))
    + N'; total modules with TRY/CATCH=' + CAST(@TryCatchModules AS nvarchar(20)) + N'. ';

SET @EvidenceParts = @EvidenceParts
    + N'Enabled Agent jobs=' + CAST(@JobCount AS nvarchar(20))
    + N'; jobs_with_on_fail_path=' + CAST(@JobsWithFailureAction AS nvarchar(20))
    + N'; jobs_notify_on_failure=' + CAST(@JobsWithNotifyFail AS nvarchar(20)) + N'.';

IF @PackageCount > 0 OR @EtlLikeModules > 0 OR @JobCount > 0
    SET @HasEtlSurface = 1;

IF @PackageCount > 0 AND @PackagesWithHandlers > 0 AND (@PackagesWithHandlers * 1.0 >= @PackageCount * 0.5)
    SET @StrongSsis = 1;
ELSE IF @PackageCount > 0 AND (@PackagesWithHandlers > 0 OR @HandlerCount > 0)
    SET @PartialSsis = 1;

IF @EtlLikeModules > 0 AND (@EtlLikeWithTryCatch * 1.0 >= @EtlLikeModules * 0.5)
    SET @StrongTsql = 1;
ELSE IF @EtlLikeWithTryCatch > 0
    SET @PartialTsql = 1;
ELSE IF @EtlLikeModules = 0 AND @TryCatchModules >= 5
    SET @PartialTsql = 1;

IF @JobCount > 0 AND (@JobsWithFailureAction * 1.0 >= @JobCount * 0.5)
    SET @StrongJobs = 1;
ELSE IF @JobsWithFailureAction > 0 OR @JobsWithNotifyFail > 0
    SET @PartialJobs = 1;

IF @HasEtlSurface = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No database found to be queried for ETL error-handling artifacts (no SSIS packages, ETL-like modules, or enabled Agent jobs). ' + @EvidenceParts;
    SET @DatabaseQueried = N'None.';
END
ELSE IF (@StrongSsis = 1 OR @StrongTsql = 1)
     AND (@StrongJobs = 1 OR @PartialJobs = 1 OR @JobCount = 0)
BEGIN
    SET @Score = 3;
    SET @Finding = N'Structured ETL error handling is evident across available surfaces. ' + @EvidenceParts;
    SET @DatabaseQueried = CASE WHEN @SsisDbExists = 1 THEN N'SSISDB; user databases; msdb' ELSE N'user databases; msdb' END;
END
ELSE IF @StrongSsis = 1 OR @StrongTsql = 1 OR @PartialSsis = 1 OR @PartialTsql = 1 OR @PartialJobs = 1 OR @StrongJobs = 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial structured error handling detected; coverage of TRY/CATCH, SSIS OnError/OnTaskFailed evidence, or Agent failure paths is incomplete. ' + @EvidenceParts;
    SET @DatabaseQueried = CASE WHEN @SsisDbExists = 1 THEN N'SSISDB; user databases; msdb' ELSE N'user databases; msdb' END;
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'ETL-related artifacts exist but structured error handling (TRY/CATCH, SSIS OnError/OnTaskFailed evidence, failure paths) was not detected. ' + @EvidenceParts;
    SET @DatabaseQueried = CASE WHEN @SsisDbExists = 1 THEN N'SSISDB; user databases; msdb' ELSE N'user databases; msdb' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#ModuleStats') IS NOT NULL DROP TABLE #ModuleStats;