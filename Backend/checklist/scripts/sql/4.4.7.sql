/* ============================================================================
   Checklist Item : 4.4.7 - Archival/purge process exists for aged data
   Scope          : SERVER (msdb Agent jobs + every accessible user database)
   Access         : Read-only - catalog views and msdb system tables only
   Output         : Result, Score, DatabaseQueried, Finding
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSqlDb BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
DECLARE @ProductMajor INT = TRY_CONVERT(INT, PARSENAME(CONVERT(NVARCHAR(128), SERVERPROPERTY('ProductVersion')), 4));
DECLARE @SupportsRetention BIT = CASE WHEN @IsAzureSqlDb = 1 OR ISNULL(@ProductMajor, 0) >= 14 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Evidence') IS NOT NULL DROP TABLE #Evidence;
IF OBJECT_ID('tempdb..#Jobs') IS NOT NULL DROP TABLE #Jobs;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;

CREATE TABLE #Db (DatabaseName SYSNAME NOT NULL);

CREATE TABLE #Evidence
(
    DatabaseName SYSNAME       NOT NULL,
    EvidenceType VARCHAR(30)   NOT NULL,
    ObjectName   NVARCHAR(520) NOT NULL,
    Detail       NVARCHAR(520) NULL
);

CREATE TABLE #Jobs
(
    JobName     NVARCHAR(256) NOT NULL,
    IsEnabled   BIT           NOT NULL,
    HasSchedule BIT           NOT NULL
);

CREATE TABLE #Skipped
(
    DatabaseName SYSNAME        NOT NULL,
    Reason       NVARCHAR(2048) NULL
);

/* ---------- 1. Databases in scope ---------- */
IF @IsAzureSqlDb = 1
    INSERT INTO #Db (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.name NOT IN ('distribution', 'SSISDB', 'ReportServer', 'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;

/* ---------- 2. Per-database evidence template ----------
   {P} is replaced by the three-part-name prefix (empty on Azure SQL Database,
   where only the current database is in scope); {DBLIT} by the quoted db name. */
DECLARE @Template NVARCHAR(MAX) = N'';

SET @Template = @Template + N'
INSERT INTO #Evidence (DatabaseName, EvidenceType, ObjectName, Detail)
SELECT {DBLIT}, ''PurgeRoutine'',
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       N''Routine named for archival/purge that performs DELETE, TRUNCATE or partition SWITCH''
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''PC'', ''FN'', ''TF'', ''IF'')
  AND (o.name LIKE ''%purge%'' OR o.name LIKE ''%archiv%'' OR o.name LIKE ''%cleanup%''
       OR o.name LIKE ''%retention%'' OR o.name LIKE ''%housekeep%'' OR o.name LIKE ''%prune%''
       OR o.name LIKE ''%rollover%'')
  AND (m.definition LIKE ''%DELETE%'' OR m.definition LIKE ''%TRUNCATE%'' OR m.definition LIKE ''%SWITCH%'');
';

SET @Template = @Template + N'
INSERT INTO #Evidence (DatabaseName, EvidenceType, ObjectName, Detail)
SELECT {DBLIT}, ''AgeBasedDelete'',
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       N''Routine deletes rows using a date/age predicate''
FROM {P}sys.sql_modules AS m
INNER JOIN {P}sys.objects AS o ON o.object_id = m.object_id
INNER JOIN {P}sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''PC'')
  AND m.definition LIKE ''%DELETE%''
  AND (m.definition LIKE ''%DATEADD%'' OR m.definition LIKE ''%GETDATE%''
       OR m.definition LIKE ''%GETUTCDATE%'' OR m.definition LIKE ''%SYSDATETIME%'')
  AND o.name NOT LIKE ''%purge%'' AND o.name NOT LIKE ''%archiv%''
  AND o.name NOT LIKE ''%cleanup%'' AND o.name NOT LIKE ''%retention%''
  AND o.name NOT LIKE ''%housekeep%'' AND o.name NOT LIKE ''%prune%''
  AND o.name NOT LIKE ''%rollover%'';
';

SET @Template = @Template + N'
INSERT INTO #Evidence (DatabaseName, EvidenceType, ObjectName, Detail)
SELECT DISTINCT {DBLIT}, ''PartitionedByDate'',
       QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name),
       N''Partitioned on '' + ty.name + N'' via function '' + pf.name + N'' with ''
         + CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM {P}sys.partition_range_values AS prv
                                  WHERE prv.function_id = pf.function_id))
         + N'' boundaries (supports sliding-window archival)''
FROM {P}sys.tables AS t
INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN {P}sys.indexes AS i ON i.object_id = t.object_id AND i.index_id IN (0, 1)
INNER JOIN {P}sys.partition_schemes AS ps ON ps.data_space_id = i.data_space_id
INNER JOIN {P}sys.partition_functions AS pf ON pf.function_id = ps.function_id
INNER JOIN {P}sys.partition_parameters AS pp ON pp.function_id = pf.function_id AND pp.parameter_id = 1
INNER JOIN {P}sys.types AS ty ON ty.user_type_id = pp.system_type_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN (''date'', ''datetime'', ''datetime2'', ''smalldatetime'', ''datetimeoffset'');
';

SET @Template = @Template + N'
INSERT INTO #Evidence (DatabaseName, EvidenceType, ObjectName, Detail)
SELECT {DBLIT}, ''ArchiveTable'',
       QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name),
       N''Table naming suggests an archive/history destination''
FROM {P}sys.tables AS t
INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE ''%archive%'' OR t.name LIKE ''%history%'' OR t.name LIKE ''%_hist'');
';

IF @SupportsRetention = 1
    SET @Template = @Template + N'
INSERT INTO #Evidence (DatabaseName, EvidenceType, ObjectName, Detail)
SELECT {DBLIT}, ''TemporalRetention'',
       QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name),
       N''Temporal history retention set to '' + CONVERT(NVARCHAR(10), t.history_retention_period)
         + N'' '' + t.history_retention_period_unit_desc
FROM {P}sys.tables AS t
INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.temporal_type = 2
  AND t.history_retention_period IS NOT NULL
  AND t.history_retention_period > 0;
';

/* ---------- 3. Collect evidence database by database ---------- */
DECLARE @DbName SYSNAME, @Prefix NVARCHAR(300), @DbLit NVARCHAR(300), @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;
        SET @DbLit  = N'''' + REPLACE(@DbName, N'''', N'''''') + N'''';
        SET @Sql    = REPLACE(REPLACE(@Template, N'{P}', @Prefix), N'{DBLIT}', @DbLit);
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName, Reason) VALUES (@DbName, ERROR_MESSAGE());
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---------- 4. SQL Agent jobs (not available on Azure SQL Database) ---------- */
DECLARE @JobsReadable BIT = 0;

IF @IsAzureSqlDb = 0 AND DB_ID('msdb') IS NOT NULL AND HAS_DBACCESS('msdb') = 1
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #Jobs (JobName, IsEnabled, HasSchedule)
SELECT j.name,
       CONVERT(BIT, j.enabled),
       CASE WHEN EXISTS (SELECT 1
                         FROM msdb.dbo.sysjobschedules AS js
                         INNER JOIN msdb.dbo.sysschedules AS sch ON sch.schedule_id = js.schedule_id
                         WHERE js.job_id = j.job_id AND sch.enabled = 1)
            THEN 1 ELSE 0 END
FROM msdb.dbo.sysjobs AS j
WHERE j.name NOT LIKE ''syspolicy%''
  AND j.name NOT LIKE ''sysutility%''
  AND (
        j.name LIKE ''%purge%'' OR j.name LIKE ''%archiv%'' OR j.name LIKE ''%cleanup%''
        OR j.name LIKE ''%retention%'' OR j.name LIKE ''%housekeep%'' OR j.name LIKE ''%prune%''
        OR EXISTS (SELECT 1
                   FROM msdb.dbo.sysjobsteps AS st
                   WHERE st.job_id = j.job_id
                     AND st.command NOT LIKE ''%sp_delete_backuphistory%''
                     AND st.command NOT LIKE ''%sp_purge_jobhistory%''
                     AND (st.command LIKE ''%purge%'' OR st.command LIKE ''%archiv%''
                          OR st.command LIKE ''%cleanup%'' OR st.command LIKE ''%retention%''
                          OR st.command LIKE ''%housekeep%'' OR st.command LIKE ''%prune%''
                          OR st.step_name LIKE ''%purge%'' OR st.step_name LIKE ''%archiv%''
                          OR st.step_name LIKE ''%cleanup%'' OR st.step_name LIKE ''%retention%''))
      );';
        EXEC sys.sp_executesql @Sql;
        SET @JobsReadable = 1;
    END TRY
    BEGIN CATCH
        SET @JobsReadable = 0;
    END CATCH
END

/* ---------- 5. Score ---------- */
DECLARE @RetentionCount    INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'TemporalRetention');
DECLARE @PurgeRoutineCount INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'PurgeRoutine');
DECLARE @AgeDeleteCount    INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'AgeBasedDelete');
DECLARE @PartitionCount    INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'PartitionedByDate');
DECLARE @ArchiveTableCount INT = (SELECT COUNT(*) FROM #Evidence WHERE EvidenceType = 'ArchiveTable');
DECLARE @JobCount          INT = (SELECT COUNT(*) FROM #Jobs);
DECLARE @ScheduledJobCount INT = (SELECT COUNT(*) FROM #Jobs WHERE IsEnabled = 1 AND HasSchedule = 1);
DECLARE @DbCount           INT = (SELECT COUNT(*) FROM #Db);
DECLARE @SkippedCount      INT = (SELECT COUNT(*) FROM #Skipped);

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);

IF @ScheduledJobCount > 0 OR @RetentionCount > 0
    SET @Score = 3;
ELSE IF @JobCount > 0 OR @PurgeRoutineCount > 0 OR @PartitionCount > 0 OR @AgeDeleteCount > 0
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* ---------- 6. Reporting values ---------- */
DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Db AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @DatabaseQueried NVARCHAR(1000) =
    CONVERT(NVARCHAR(10), @DbCount) + N' user database(s) + msdb: '
    + CASE
        WHEN @DbList IS NULL THEN N'(none accessible)'
        WHEN LEN(@DbList) > 400 THEN LEFT(@DbList, 397) + N'...'
        ELSE @DbList
      END;

DECLARE @JobExamples NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N'; ' + j.JobName
                  + N' (enabled=' + CONVERT(NVARCHAR(1), j.IsEnabled)
                  + N', scheduled=' + CONVERT(NVARCHAR(1), j.HasSchedule) + N')'
           FROM #Jobs AS j
           ORDER BY j.IsEnabled DESC, j.HasSchedule DESC, j.JobName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @ObjExamples NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N'; ' + e.DatabaseName + N'.' + e.ObjectName + N' [' + e.EvidenceType + N']'
           FROM #Evidence AS e
           WHERE e.EvidenceType <> 'ArchiveTable'
           ORDER BY CASE e.EvidenceType
                        WHEN 'TemporalRetention'  THEN 1
                        WHEN 'PurgeRoutine'       THEN 2
                        WHEN 'PartitionedByDate'  THEN 3
                        ELSE 4
                    END,
                    e.DatabaseName, e.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Finding NVARCHAR(MAX) =
      N'Archival/purge evidence across ' + CONVERT(NVARCHAR(10), @DbCount) + N' database(s): '
    + N'scheduled+enabled purge/archive Agent jobs=' + CONVERT(NVARCHAR(10), @ScheduledJobCount)
    + N' (matching jobs total=' + CONVERT(NVARCHAR(10), @JobCount) + N')'
    + N', temporal tables with finite history retention=' + CONVERT(NVARCHAR(10), @RetentionCount)
    + N', purge/archive-named routines=' + CONVERT(NVARCHAR(10), @PurgeRoutineCount)
    + N', age-predicate delete routines=' + CONVERT(NVARCHAR(10), @AgeDeleteCount)
    + N', date-partitioned tables=' + CONVERT(NVARCHAR(10), @PartitionCount)
    + N', archive/history-named tables=' + CONVERT(NVARCHAR(10), @ArchiveTableCount) + N'.'
    + ISNULL(N' Example objects: ' + @ObjExamples + N'.', N'')
    + ISNULL(N' Example jobs: ' + @JobExamples + N'.', N'')
    + CASE WHEN @Score = 3 THEN N' An automated retention mechanism is in place.'
           WHEN @Score = 2 THEN N' A purge/archive capability exists but no enabled, scheduled automation or declarative retention policy was found; confirm how and when it runs.'
           ELSE N' No archival, purge or retention mechanism was detected; aged data appears to accumulate indefinitely.'
      END
    + CASE WHEN @IsAzureSqlDb = 1
           THEN N' Azure SQL Database: SQL Agent is unavailable, so Elastic Jobs or external schedulers cannot be inspected from this connection.'
           WHEN @JobsReadable = 0
           THEN N' SQL Agent job metadata in msdb could not be read with the current permissions, so job-based purges may be under-reported.'
           ELSE N'' END
    + CASE WHEN @SkippedCount > 0
           THEN N' ' + CONVERT(NVARCHAR(10), @SkippedCount) + N' database(s) were skipped due to access or state errors.'
           ELSE N'' END
    + N' Detection is pattern-based (object naming and module text); confirm findings against the documented retention standard.';

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #Db;
DROP TABLE #Evidence;
DROP TABLE #Jobs;
DROP TABLE #Skipped;