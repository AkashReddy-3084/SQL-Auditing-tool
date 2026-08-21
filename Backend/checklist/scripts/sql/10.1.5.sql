/* ============================================================================
   Checklist 10.1.5 - Long-running/blocking query alerting configured
   Scope : SERVER
   Mode  : READ-ONLY (catalog/DMV reads only)
   Output: Result, Score, DatabaseQueried, Finding
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSqlDb  BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) IN (5, 6, 9, 11) THEN 1 ELSE 0 END;
DECLARE @sql NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;
CREATE TABLE #Evidence
(
    Category   NVARCHAR(20)  NOT NULL,   -- BLOCKING | LONGRUN | NOTIFY | THRESHOLD
    ObjectName NVARCHAR(300) NOT NULL,
    Detail     NVARCHAR(600) NULL,
    IsActive   BIT           NOT NULL
);

/* ---- 1. blocked process threshold - enables blocked process reporting ---- */
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT N'THRESHOLD',
       N'sp_configure: blocked process threshold (s)',
       N'value_in_use = ' + CONVERT(NVARCHAR(20), CONVERT(INT, c.value_in_use)),
       CASE WHEN CONVERT(INT, c.value_in_use) > 0 THEN 1 ELSE 0 END
FROM sys.configurations AS c
WHERE c.name = N'blocked process threshold (s)';

/* ---- 2. Extended Events sessions capturing blocking / long-running work ---- */
IF @IsAzureSqlDb = 0 AND OBJECT_ID(N'sys.server_event_sessions') IS NOT NULL
BEGIN
    SET @sql = N'
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT CASE WHEN e.name = N''blocked_process_report'' THEN N''BLOCKING'' ELSE N''LONGRUN'' END,
       N''XEvent session: '' + s.name,
       N''event = '' + e.name
         + N'', predicate = '' + ISNULL(LEFT(CONVERT(NVARCHAR(MAX), e.predicate), 150), N''(none)'')
         + N'', running = '' + CASE WHEN x.name IS NULL THEN N''NO'' ELSE N''YES'' END,
       CASE WHEN x.name IS NULL THEN 0 ELSE 1 END
FROM sys.server_event_sessions AS s
INNER JOIN sys.server_event_session_events AS e
        ON e.event_session_id = s.event_session_id
LEFT JOIN sys.dm_xe_sessions AS x
        ON x.name = s.name
WHERE e.name = N''blocked_process_report''
   OR ( e.name IN (N''sql_batch_completed'', N''rpc_completed'', N''sql_statement_completed'', N''sp_statement_completed'')
        AND CONVERT(NVARCHAR(MAX), e.predicate) LIKE N''%duration%'' );';
    EXEC sys.sp_executesql @sql;
END
ELSE IF OBJECT_ID(N'sys.database_event_sessions') IS NOT NULL
BEGIN
    SET @sql = N'
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT CASE WHEN e.name = N''blocked_process_report'' THEN N''BLOCKING'' ELSE N''LONGRUN'' END,
       N''XEvent session (database-scoped): '' + s.name,
       N''event = '' + e.name
         + N'', predicate = '' + ISNULL(LEFT(CONVERT(NVARCHAR(MAX), e.predicate), 150), N''(none)'')
         + N'', running = '' + CASE WHEN x.name IS NULL THEN N''NO'' ELSE N''YES'' END,
       CASE WHEN x.name IS NULL THEN 0 ELSE 1 END
FROM sys.database_event_sessions AS s
INNER JOIN sys.database_event_session_events AS e
        ON e.event_session_id = s.event_session_id
LEFT JOIN sys.dm_xe_database_sessions AS x
        ON x.name = s.name
WHERE e.name = N''blocked_process_report''
   OR ( e.name IN (N''sql_batch_completed'', N''rpc_completed'', N''sql_statement_completed'', N''sp_statement_completed'')
        AND CONVERT(NVARCHAR(MAX), e.predicate) LIKE N''%duration%'' );';
    EXEC sys.sp_executesql @sql;
END

/* ---- 3. SQL Agent alerts targeting blocking / long-running conditions ---- */
IF OBJECT_ID(N'msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SET @sql = N'
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT CASE WHEN a.wmi_query LIKE N''%BLOCKED_PROCESS_REPORT%''
              OR a.performance_condition LIKE N''%Processes blocked%''
              OR a.performance_condition LIKE N''%Lock Waits%''
              OR a.name LIKE N''%block%''
            THEN N''BLOCKING'' ELSE N''LONGRUN'' END,
       N''SQL Agent alert: '' + a.name,
       N''enabled='' + CONVERT(NVARCHAR(5), a.enabled)
         + N'', wmi_query='' + ISNULL(LEFT(a.wmi_query, 150), N''(none)'')
         + N'', perf_condition='' + ISNULL(a.performance_condition, N''(none)'')
         + N'', notifications='' + CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM msdb.dbo.sysnotifications AS n WHERE n.alert_id = a.id)),
       CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END
FROM msdb.dbo.sysalerts AS a
WHERE a.wmi_query LIKE N''%BLOCKED_PROCESS_REPORT%''
   OR a.performance_condition LIKE N''%Processes blocked%''
   OR a.performance_condition LIKE N''%Lock Waits%''
   OR a.performance_condition LIKE N''%Longest Transaction Running Time%''
   OR a.name LIKE N''%block%''
   OR a.name LIKE N''%long%run%''
   OR a.name LIKE N''%runaway%'';';
    EXEC sys.sp_executesql @sql;
END

/* ---- 4. Notification path for those alerts (operator + email) ---- */
IF OBJECT_ID(N'msdb.dbo.sysnotifications') IS NOT NULL
   AND OBJECT_ID(N'msdb.dbo.sysoperators') IS NOT NULL
   AND OBJECT_ID(N'msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SET @sql = N'
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT N''NOTIFY'',
       N''Alert notification: '' + a.name + N'' -> '' + o.name,
       N''alert enabled='' + CONVERT(NVARCHAR(5), a.enabled)
         + N'', operator enabled='' + CONVERT(NVARCHAR(5), o.enabled)
         + N'', email='' + ISNULL(o.email_address, N''(none)''),
       CASE WHEN a.enabled = 1 AND o.enabled = 1 AND o.email_address IS NOT NULL THEN 1 ELSE 0 END
FROM msdb.dbo.sysnotifications AS n
INNER JOIN msdb.dbo.sysalerts AS a ON a.id = n.alert_id
INNER JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id
WHERE a.wmi_query LIKE N''%BLOCKED_PROCESS_REPORT%''
   OR a.performance_condition LIKE N''%Processes blocked%''
   OR a.performance_condition LIKE N''%Lock Waits%''
   OR a.performance_condition LIKE N''%Longest Transaction Running Time%''
   OR a.name LIKE N''%block%''
   OR a.name LIKE N''%long%run%''
   OR a.name LIKE N''%runaway%'';';
    EXEC sys.sp_executesql @sql;
END

/* ---- 5. Scheduled SQL Agent jobs used as blocking / long-running monitors ---- */
IF OBJECT_ID(N'msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SET @sql = N'
INSERT INTO #Evidence (Category, ObjectName, Detail, IsActive)
SELECT CASE WHEN j.name LIKE N''%block%'' THEN N''BLOCKING'' ELSE N''LONGRUN'' END,
       N''SQL Agent job: '' + j.name,
       N''enabled='' + CONVERT(NVARCHAR(5), j.enabled)
         + N'', active schedule='' + CASE WHEN EXISTS (SELECT 1
                                                       FROM msdb.dbo.sysjobschedules AS js
                                                       INNER JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
                                                       WHERE js.job_id = j.job_id AND sc.enabled = 1)
                                          THEN N''YES'' ELSE N''NO'' END,
       CASE WHEN j.enabled = 1
                 AND EXISTS (SELECT 1
                             FROM msdb.dbo.sysjobschedules AS js
                             INNER JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
                             WHERE js.job_id = j.job_id AND sc.enabled = 1)
            THEN 1 ELSE 0 END
FROM msdb.dbo.sysjobs AS j
WHERE j.name LIKE N''%block%''
   OR j.name LIKE N''%long%run%''
   OR j.name LIKE N''%runaway%''
   OR j.name LIKE N''%query%monitor%'';';
    EXEC sys.sp_executesql @sql;
END

/* ---- 6. Scoring ---- */
DECLARE @Blocking   INT = (SELECT COUNT(*) FROM #Evidence WHERE Category = N'BLOCKING'  AND IsActive = 1);
DECLARE @LongRun    INT = (SELECT COUNT(*) FROM #Evidence WHERE Category = N'LONGRUN'   AND IsActive = 1);
DECLARE @Notify     INT = (SELECT COUNT(*) FROM #Evidence WHERE Category = N'NOTIFY'    AND IsActive = 1);
DECLARE @Threshold  INT = (SELECT COUNT(*) FROM #Evidence WHERE Category = N'THRESHOLD' AND IsActive = 1);
DECLARE @AnyDefined INT = (SELECT COUNT(*) FROM #Evidence WHERE Category IN (N'BLOCKING', N'LONGRUN'));

DECLARE @Score   INT;
DECLARE @Result  NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Details NVARCHAR(MAX);

SET @Details = STUFF((SELECT N' | ' + e.Category + N' :: ' + e.ObjectName + N' [' + ISNULL(e.Detail, N'') + N']'
                      FROM #Evidence AS e
                      ORDER BY e.Category, e.ObjectName
                      FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 3, N'');
SET @Details = ISNULL(LEFT(@Details, 1500), N'no blocking or long-running alerting artifacts found');

IF @Blocking > 0 AND @LongRun > 0 AND @Notify > 0
    SET @Score = 3;
ELSE IF (@Blocking > 0 OR @LongRun > 0) AND @Notify > 0
    SET @Score = 2;
ELSE IF @Blocking > 0 OR @LongRun > 0 OR @AnyDefined > 0 OR @Threshold > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                   WHEN @Score = 2 THEN N'NeedsReview'
                   ELSE N'Fail' END;

/* Azure SQL Database has no SQL Agent; alert rules live in Azure Monitor and cannot be read from T-SQL. */
IF @IsAzureSqlDb = 1 AND @Score < 3
    SET @Result = N'NeedsReview';

SET @Finding = N'Active blocking-alert artifacts: ' + CONVERT(NVARCHAR(10), @Blocking)
             + N'; active long-running-alert artifacts: ' + CONVERT(NVARCHAR(10), @LongRun)
             + N'; active notification paths: ' + CONVERT(NVARCHAR(10), @Notify)
             + N'; blocked process threshold configured: ' + CASE WHEN @Threshold > 0 THEN N'YES' ELSE N'NO' END
             + N'; EngineEdition = ' + CONVERT(NVARCHAR(10), @EngineEdition)
             + CASE WHEN @IsAzureSqlDb = 1
                    THEN N'; Azure SQL Database detected - SQL Agent alerting is unavailable, Azure Monitor alert rules must be confirmed in the portal'
                    ELSE N'' END
             + N'. Evidence: ' + @Details;

SELECT @Result                             AS Result,
       @Score                              AS Score,
       CONVERT(NVARCHAR(128), DB_NAME())   AS DatabaseQueried,
       @Finding                            AS Finding;

IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;