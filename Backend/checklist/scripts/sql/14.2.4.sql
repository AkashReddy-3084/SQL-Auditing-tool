SET NOCOUNT ON;

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(128) = N'msdb';
DECLARE @Finding         NVARCHAR(4000);
DECLARE @Evaluated       BIT = 0;

IF @EngineEdition = 5
BEGIN
    SET @Evaluated       = 1;
    SET @Score           = 1;
    SET @DatabaseQueried = N'N/A (Azure SQL Database)';
    SET @Finding         = N'EngineEdition = 5 (Azure SQL Database). SQL Server Agent and msdb are not available on this platform, so fragmentation-based index maintenance automation cannot be evidenced from T-SQL. Manually confirm that Elastic Jobs, Azure Automation runbooks, or an equivalent scheduled process performs fragmentation-driven index rebuild/reorganize.';
END
ELSE IF DB_ID(N'msdb') IS NULL OR HAS_DBACCESS(N'msdb') <> 1
BEGIN
    SET @Evaluated = 1;
    SET @Score     = 1;
    SET @Finding   = N'msdb is not present or not accessible to the current login, so SQL Agent job metadata could not be read. Grant read access to msdb (for example SQLAgentReaderRole) and re-run, or manually confirm that fragmentation-based index maintenance is automated.';
END

IF @Evaluated = 0
BEGIN
    CREATE TABLE #IndexMaintJobs
    (
        job_name             SYSNAME        NOT NULL,
        is_enabled           BIT            NOT NULL,
        has_enabled_schedule BIT            NOT NULL,
        is_frag_aware        BIT            NOT NULL,
        source_type          NVARCHAR(30)   NOT NULL
    );

    -- Jobs whose step commands perform index rebuild/reorganize directly
    INSERT INTO #IndexMaintJobs (job_name, is_enabled, has_enabled_schedule, is_frag_aware, source_type)
    SELECT
        j.name,
        j.enabled,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobschedules AS js
            INNER JOIN msdb.dbo.sysschedules AS s
                ON s.schedule_id = js.schedule_id
            WHERE js.job_id = j.job_id
              AND s.enabled = 1
        ) THEN 1 ELSE 0 END,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobsteps AS sf
            WHERE sf.job_id = j.job_id
              AND
              (
                    sf.command LIKE N'%avg_fragmentation_in_percent%'
                 OR sf.command LIKE N'%dm_db_index_physical_stats%'
                 OR sf.command LIKE N'%FragmentationLevel%'
                 OR sf.command LIKE N'%IndexOptimize%'
                 OR sf.command LIKE N'%IndexDefrag%'
                 OR sf.command LIKE N'%avg_page_space_used_in_percent%'
              )
        ) THEN 1 ELSE 0 END,
        N'Agent job'
    FROM msdb.dbo.sysjobs AS j
    WHERE EXISTS
    (
        SELECT 1
        FROM msdb.dbo.sysjobsteps AS st
        WHERE st.job_id = j.job_id
          AND
          (
                st.command LIKE N'%ALTER INDEX%'
             OR st.command LIKE N'%DBCC DBREINDEX%'
             OR st.command LIKE N'%DBCC INDEXDEFRAG%'
             OR st.command LIKE N'%IndexOptimize%'
             OR st.command LIKE N'%IndexDefrag%'
          )
    );

    -- Maintenance-plan driven jobs not already captured above
    INSERT INTO #IndexMaintJobs (job_name, is_enabled, has_enabled_schedule, is_frag_aware, source_type)
    SELECT
        j.name,
        j.enabled,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobschedules AS js
            INNER JOIN msdb.dbo.sysschedules AS s
                ON s.schedule_id = js.schedule_id
            WHERE js.job_id = j.job_id
              AND s.enabled = 1
        ) THEN 1 ELSE 0 END,
        0,
        N'Maintenance plan'
    FROM msdb.dbo.sysjobs AS j
    WHERE EXISTS
          (
              SELECT 1
              FROM msdb.dbo.sysmaintplan_subplans AS sp
              WHERE sp.job_id = j.job_id
          )
      AND NOT EXISTS
          (
              SELECT 1
              FROM #IndexMaintJobs AS im
              WHERE im.job_name = j.name
          );

    DECLARE @Total         INT,
            @FragAwareLive INT,
            @LiveNotFrag   INT,
            @NotScheduled  INT,
            @NameList      NVARCHAR(MAX);

    SELECT
        @Total         = COUNT(*),
        @FragAwareLive = SUM(CASE WHEN is_enabled = 1 AND has_enabled_schedule = 1 AND is_frag_aware = 1 THEN 1 ELSE 0 END),
        @LiveNotFrag   = SUM(CASE WHEN is_enabled = 1 AND has_enabled_schedule = 1 AND is_frag_aware = 0 THEN 1 ELSE 0 END),
        @NotScheduled  = SUM(CASE WHEN is_enabled = 0 OR  has_enabled_schedule = 0 THEN 1 ELSE 0 END)
    FROM #IndexMaintJobs;

    SET @NameList =
    (
        SELECT STUFF
        ((
            SELECT TOP (15) N'; ' + im.job_name
                          + N' [' + im.source_type
                          + N', enabled=' + CASE WHEN im.is_enabled = 1 THEN N'Y' ELSE N'N' END
                          + N', scheduled=' + CASE WHEN im.has_enabled_schedule = 1 THEN N'Y' ELSE N'N' END
                          + N', fragmentation-aware=' + CASE WHEN im.is_frag_aware = 1 THEN N'Y' ELSE N'N' END
                          + N']'
            FROM #IndexMaintJobs AS im
            ORDER BY im.is_frag_aware DESC, im.job_name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')
    );

    IF @Total = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No SQL Agent job or maintenance plan performing index rebuild/reorganize was found in msdb. Fragmentation-based index maintenance is not automated on this instance.';
    END
    ELSE IF @FragAwareLive > 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = CAST(@FragAwareLive AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10))
                     + N' index-maintenance job(s) are enabled, have an enabled schedule, and use fragmentation thresholds (references to avg_fragmentation_in_percent / dm_db_index_physical_stats / IndexOptimize / FragmentationLevel). Jobs found: '
                     + LEFT(ISNULL(@NameList, N'(none)'), 3000);
    END
    ELSE IF @LiveNotFrag > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = CAST(@LiveNotFrag AS NVARCHAR(10)) + N' enabled and scheduled index-maintenance job(s) exist, but no fragmentation threshold logic could be confirmed from the job step commands or the maintenance plan definition (blanket rebuild/reorganize or opaque SSIS maintenance plan). Jobs found: '
                     + LEFT(ISNULL(@NameList, N'(none)'), 3000);
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = CAST(@NotScheduled AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10))
                     + N' index-maintenance job(s) are disabled or have no enabled schedule, so fragmentation-based maintenance does not run automatically. Jobs found: '
                     + LEFT(ISNULL(@NameList, N'(none)'), 3000);
    END

    DROP TABLE #IndexMaintJobs;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;