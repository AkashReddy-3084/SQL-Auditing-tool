-- Checklist: SQL Agent / scheduler jobs inventoried and owned
-- Scope: SERVER
-- Scoring: 3 = every job owner resolves to an enabled login and every job is categorised and described; 2 = owners all resolve but inventory metadata is incomplete, under 5% of jobs unowned, or no Agent jobs exist; 1 = under 25% of jobs orphaned or owned by a disabled login; 0 = 25% or more unowned, or the inventory could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SQL Agent job inventory could not be read';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Collected INT = 0;
DECLARE @Total INT = 0;
DECLARE @EnabledJobs INT = 0;
DECLARE @Orphaned INT = 0;
DECLARE @DisabledOwner INT = 0;
DECLARE @Uncategorized INT = 0;
DECLARE @NoDescription INT = 0;
DECLARE @NoSchedule INT = 0;
DECLARE @Bad INT = 0;
DECLARE @BadNames NVARCHAR(MAX) = 'none';
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Server Agent and msdb do not exist on this platform, so no in-engine job inventory could be enumerated. Scheduled work runs in Elastic Jobs, Azure Automation, Logic Apps or Data Factory, where its inventory and named owners are held.';
END
ELSE
BEGIN
    CREATE TABLE #AgentJobs (JobName NVARCHAR(256) NULL, IsEnabled INT NULL, OwnerName NVARCHAR(256) NULL,
        CategoryName NVARCHAR(256) NULL, JobDescription NVARCHAR(512) NULL, HasSchedule INT NULL,
        OwnerOrphaned INT NULL, OwnerDisabled INT NULL);

    BEGIN TRY
        SET @Sql = N'SELECT j.name, CONVERT(INT, j.enabled), SUSER_SNAME(j.owner_sid), ISNULL(c.name, N''''), ISNULL(j.description, N''''),
            CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules AS s WHERE s.job_id = j.job_id) THEN 1 ELSE 0 END,
            CASE WHEN SUSER_SNAME(j.owner_sid) IS NULL THEN 1 ELSE 0 END,
            CASE WHEN p.principal_id IS NOT NULL AND p.is_disabled = 1 THEN 1 ELSE 0 END
            FROM msdb.dbo.sysjobs AS j
            LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
            LEFT JOIN sys.server_principals AS p ON p.sid = j.owner_sid;';
        INSERT INTO #AgentJobs (JobName, IsEnabled, OwnerName, CategoryName, JobDescription, HasSchedule, OwnerOrphaned, OwnerDisabled)
        EXEC sys.sp_executesql @Sql;
        SET @Collected = 1;
    END TRY
    BEGIN CATCH
        SET @Collected = 0;
    END CATCH;

    IF @Collected = 1
    BEGIN
        SELECT @Total = COUNT(*),
               @EnabledJobs = ISNULL(SUM(CASE WHEN IsEnabled = 1 THEN 1 ELSE 0 END), 0),
               @Orphaned = ISNULL(SUM(CASE WHEN OwnerOrphaned = 1 THEN 1 ELSE 0 END), 0),
               @DisabledOwner = ISNULL(SUM(CASE WHEN OwnerOrphaned = 0 AND OwnerDisabled = 1 THEN 1 ELSE 0 END), 0),
               @Uncategorized = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ISNULL(CategoryName, N''))) IN (N'', N'[Uncategorized (Local)]', N'[Uncategorized]', N'[Uncategorized (Multi-Server)]') THEN 1 ELSE 0 END), 0),
               @NoDescription = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ISNULL(JobDescription, N''))) IN (N'', N'No description available.') THEN 1 ELSE 0 END), 0),
               @NoSchedule = ISNULL(SUM(CASE WHEN HasSchedule = 0 THEN 1 ELSE 0 END), 0)
        FROM #AgentJobs;

        SELECT @BadNames = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
                   ISNULL(JobName, N'(unnamed)') + N' [owner=' + ISNULL(OwnerName, N'orphaned SID') + N']'), ', '), 'none')
        FROM #AgentJobs
        WHERE OwnerOrphaned = 1 OR OwnerDisabled = 1;
    END

    DROP TABLE #AgentJobs;

    SET @Total = ISNULL(@Total, 0);
    SET @Bad = ISNULL(@Orphaned, 0) + ISNULL(@DisabledOwner, 0);
    SET @BadNames = ISNULL(@BadNames, 'none');

    SET @Score = CASE
        WHEN @Collected = 0 THEN 0
        WHEN @Total = 0 THEN 2
        WHEN @Bad = 0 AND @Uncategorized = 0 AND @NoDescription = 0 THEN 3
        WHEN @Bad * 100 <= 5 * @Total THEN 2
        WHEN @Bad * 100 < 25 * @Total THEN 1
        ELSE 0
    END;

    SET @Finding = CASE
        WHEN @Collected = 0
            THEN 'The SQL Agent job inventory in msdb.dbo.sysjobs could not be read with the audit login, so job ownership could not be verified.'
        WHEN @Total = 0
            THEN 'No SQL Server Agent jobs are defined on this instance, so there is no in-engine job inventory to own; scheduled work for this instance is driven by an external scheduler whose inventory is held outside the engine.'
        ELSE CONCAT('SQL Agent jobs = ', @Total, ' (', @EnabledJobs, ' enabled); orphaned owner SID = ', @Orphaned,
             ', owned by a disabled login = ', @DisabledOwner, ', uncategorised = ', @Uncategorized,
             ', without a description = ', @NoDescription, ', without a schedule = ', @NoSchedule,
             '. Jobs with an unresolvable or disabled owner: ', LEFT(@BadNames, 1000), '.')
    END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;