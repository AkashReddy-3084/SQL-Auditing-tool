/*
    Checklist Item : 10.4.4 - SQL Agent / scheduler jobs inventoried and owned
    Area           : Monitoring & Observability
    Scope          : SERVER
    Type           : Read-only (catalog/metadata reads only; temp table used for staging)
    Output         : Result, Score, DatabaseQueried, Finding
*/

SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT            = 1;
DECLARE @DatabaseQueried  NVARCHAR(256)  = N'msdb';
DECLARE @Finding          NVARCHAR(4000) = N'';

DECLARE @EngineEdition    INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Collected        BIT = 0;

DECLARE @TotalJobs        INT = 0;
DECLARE @EnabledJobs      INT = 0;
DECLARE @OrphanOwner      INT = 0;
DECLARE @DisabledOwner    INT = 0;
DECLARE @Uncategorized    INT = 0;
DECLARE @NoDescription    INT = 0;
DECLARE @NoSchedule       INT = 0;
DECLARE @BadOwner         INT = 0;
DECLARE @Detail           NVARCHAR(2000) = N'';
DECLARE @Sql              NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score           = 2;
    SET @DatabaseQueried = N'N/A (Azure SQL Database)';
    SET @Finding         = N'Not applicable: EngineEdition 5 (Azure SQL Database) detected. SQL Server Agent and the msdb database do not exist on this platform, so an in-engine job inventory cannot be produced. Scheduled work is delivered by Elastic Jobs, Azure Automation, Logic Apps or Data Factory and must be inventoried and assigned an accountable owner in those services instead.';
END
ELSE IF DB_ID(N'msdb') IS NULL
BEGIN
    SET @Score           = 1;
    SET @DatabaseQueried = N'N/A (msdb not accessible)';
    SET @Finding         = N'The msdb database is not present or is not visible to the audit login, so the SQL Server Agent job inventory could not be enumerated and job ownership could not be verified. Re-run this check with a login holding SQLAgentReaderRole in msdb or sysadmin.';
END
ELSE
BEGIN
    CREATE TABLE #AgentJobs
    (
        JobId           UNIQUEIDENTIFIER NULL,
        JobName         NVARCHAR(256)    NULL,
        IsEnabled       INT              NULL,
        OwnerName       NVARCHAR(256)    NULL,
        CategoryName    NVARCHAR(256)    NULL,
        JobDescription  NVARCHAR(512)    NULL,
        HasSchedule     INT              NULL,
        OwnerIsOrphaned INT              NULL,
        OwnerIsDisabled INT              NULL
    );

    SET @Sql = N'
        SELECT  j.job_id,
                j.name,
                CAST(j.enabled AS INT),
                SUSER_SNAME(j.owner_sid),
                ISNULL(c.name, N''''),
                ISNULL(j.description, N''''),
                CASE WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobschedules AS js
                                  WHERE js.job_id = j.job_id) THEN 1 ELSE 0 END,
                CASE WHEN SUSER_SNAME(j.owner_sid) IS NULL THEN 1 ELSE 0 END,
                CASE WHEN sp.principal_id IS NOT NULL AND sp.is_disabled = 1 THEN 1 ELSE 0 END
        FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobs AS j
        LEFT JOIN ' + QUOTENAME(N'msdb') + N'.dbo.syscategories AS c
               ON c.category_id = j.category_id
        LEFT JOIN sys.server_principals AS sp
               ON sp.sid = j.owner_sid;';

    BEGIN TRY
        INSERT INTO #AgentJobs
            (JobId, JobName, IsEnabled, OwnerName, CategoryName, JobDescription,
             HasSchedule, OwnerIsOrphaned, OwnerIsDisabled)
        EXEC sys.sp_executesql @Sql;

        SET @Collected = 1;
    END TRY
    BEGIN CATCH
        SET @Collected       = 0;
        SET @Score           = 1;
        SET @DatabaseQueried = N'msdb';
        SET @Finding         = N'The SQL Server Agent job inventory in msdb could not be read, so job ownership could not be verified: ' +
                               LEFT(ISNULL(ERROR_MESSAGE(), N'unknown error'), 500) +
                               N' Grant the audit login membership of SQLAgentReaderRole in msdb (or sysadmin) and re-run.';
    END CATCH;

    IF @Collected = 1
    BEGIN
        SELECT  @TotalJobs     = COUNT(*),
                @EnabledJobs   = SUM(CASE WHEN IsEnabled = 1 THEN 1 ELSE 0 END),
                @OrphanOwner   = SUM(CASE WHEN OwnerIsOrphaned = 1 THEN 1 ELSE 0 END),
                @DisabledOwner = SUM(CASE WHEN OwnerIsOrphaned = 0 AND OwnerIsDisabled = 1 THEN 1 ELSE 0 END),
                @Uncategorized = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(CategoryName, N''))) IN
                                          (N'', N'[Uncategorized (Local)]', N'[Uncategorized]', N'[Uncategorized (Multi-Server)]')
                                     THEN 1 ELSE 0 END),
                @NoDescription = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(JobDescription, N''))) IN
                                          (N'', N'No description available.')
                                     THEN 1 ELSE 0 END),
                @NoSchedule    = SUM(CASE WHEN HasSchedule = 0 THEN 1 ELSE 0 END)
        FROM #AgentJobs;

        SET @TotalJobs     = ISNULL(@TotalJobs, 0);
        SET @EnabledJobs   = ISNULL(@EnabledJobs, 0);
        SET @OrphanOwner   = ISNULL(@OrphanOwner, 0);
        SET @DisabledOwner = ISNULL(@DisabledOwner, 0);
        SET @Uncategorized = ISNULL(@Uncategorized, 0);
        SET @NoDescription = ISNULL(@NoDescription, 0);
        SET @NoSchedule    = ISNULL(@NoSchedule, 0);
        SET @BadOwner      = @OrphanOwner + @DisabledOwner;

        SET @Detail = ISNULL(STUFF((
                SELECT TOP (10) N'; ' + ISNULL(j.JobName, N'(unnamed)') +
                       N' [owner=' + ISNULL(j.OwnerName, N'ORPHANED SID') + N']'
                FROM #AgentJobs AS j
                WHERE j.OwnerIsOrphaned = 1
                   OR j.OwnerIsDisabled = 1
                   OR LTRIM(RTRIM(ISNULL(j.CategoryName, N''))) IN
                        (N'', N'[Uncategorized (Local)]', N'[Uncategorized]', N'[Uncategorized (Multi-Server)]')
                   OR LTRIM(RTRIM(ISNULL(j.JobDescription, N''))) IN (N'', N'No description available.')
                ORDER BY j.OwnerIsOrphaned DESC, j.OwnerIsDisabled DESC, j.JobName
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

        IF @TotalJobs = 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'No SQL Server Agent jobs are defined on this instance (msdb.dbo.sysjobs returned 0 rows), so there is no in-engine job inventory to own. Confirm that scheduled maintenance, backup and ETL work for this instance is delivered by an external scheduler and that those jobs are inventoried with named owners.';
        END
        ELSE IF @BadOwner = 0 AND @Uncategorized = 0 AND @NoDescription = 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'All ' + CAST(@TotalJobs AS NVARCHAR(10)) + N' SQL Server Agent job(s) are fully inventoried and owned: ' +
                           CAST(@EnabledJobs AS NVARCHAR(10)) + N' enabled, every job owner SID resolves to an enabled server login, every job is assigned to a real category, and every job carries a description. ' +
                           CAST(@NoSchedule AS NVARCHAR(10)) + N' job(s) have no attached schedule (on-demand or externally triggered).';
        END
        ELSE IF @BadOwner = 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'All ' + CAST(@TotalJobs AS NVARCHAR(10)) + N' SQL Server Agent job(s) resolve to an enabled owner login, but the inventory metadata is incomplete: ' +
                           CAST(@Uncategorized AS NVARCHAR(10)) + N' uncategorised, ' +
                           CAST(@NoDescription AS NVARCHAR(10)) + N' without a description, ' +
                           CAST(@NoSchedule AS NVARCHAR(10)) + N' with no schedule attached. Affected job(s): ' +
                           LEFT(@Detail, 1500) + N'.';
        END
        ELSE IF (@BadOwner * 100) / @TotalJobs <= 50
        BEGIN
            SET @Score   = 1;
            SET @Finding = N'Ownership is partially unaccountable: of ' + CAST(@TotalJobs AS NVARCHAR(10)) +
                           N' SQL Server Agent job(s), ' + CAST(@OrphanOwner AS NVARCHAR(10)) +
                           N' have an orphaned owner SID that no longer maps to a server login and ' +
                           CAST(@DisabledOwner AS NVARCHAR(10)) + N' are owned by a disabled login. Inventory metadata gaps: ' +
                           CAST(@Uncategorized AS NVARCHAR(10)) + N' uncategorised, ' +
                           CAST(@NoDescription AS NVARCHAR(10)) + N' without a description. Affected job(s): ' +
                           LEFT(@Detail, 1400) + N'.';
        END
        ELSE
        BEGIN
            SET @Score   = 0;
            SET @Finding = N'The SQL Server Agent job inventory is largely unowned: ' + CAST(@BadOwner AS NVARCHAR(10)) +
                           N' of ' + CAST(@TotalJobs AS NVARCHAR(10)) + N' job(s) have an orphaned owner SID (' +
                           CAST(@OrphanOwner AS NVARCHAR(10)) + N') or a disabled owner login (' +
                           CAST(@DisabledOwner AS NVARCHAR(10)) + N'). Inventory metadata gaps: ' +
                           CAST(@Uncategorized AS NVARCHAR(10)) + N' uncategorised, ' +
                           CAST(@NoDescription AS NVARCHAR(10)) + N' without a description. Affected job(s): ' +
                           LEFT(@Detail, 1400) + N'.';
        END
    END

    IF OBJECT_ID(N'tempdb..#AgentJobs') IS NOT NULL
        DROP TABLE #AgentJobs;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT  @Result          AS Result,
        @Score           AS Score,
        @DatabaseQueried AS DatabaseQueried,
        LEFT(@Finding, 4000) AS Finding;