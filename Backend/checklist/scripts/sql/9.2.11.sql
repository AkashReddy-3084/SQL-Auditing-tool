-- Checklist: Backup preference configured (backups taken from the preferred / secondary replica where used) and validated across failover
-- Scope: SERVER
-- Scoring: 3 = availability group preference set, prioritised replicas present and recent history written by a prioritised replica, or platform-managed on Azure SQL Database; 2 = availability group with two of those three signals, or no availability group in use and recent history exists; 1 = only one signal, or an availability group with no supporting evidence; 0 = no evidence at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Replica backup preference evidence was unavailable';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @AgCount INT = 0;
DECLARE @AgWithPref INT = 0;
DECLARE @PriorityReplicas INT = 0;
DECLARE @RecentHistory INT = 0;
DECLARE @PreferredSource INT = 0;
DECLARE @Signals INT = 0;
DECLARE @PrefDesc NVARCHAR(400) = 'none';
DECLARE @ReadNote NVARCHAR(300) = '';
DECLARE @M TABLE (K NVARCHAR(40), V INT NULL, T NVARCHAR(400) NULL);

IF @Edition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): automated backups and the replica they are taken from are selected and validated by the platform across failover; no availability replica backup preference is exposed to or configurable by the tenant.';
END
ELSE
BEGIN
    SET @Sql = N'
SELECT ''AgCount'', COUNT(*), CONVERT(NVARCHAR(400), NULL) FROM sys.availability_groups
UNION ALL SELECT ''AgWithPref'', COUNT(*), NULL FROM sys.availability_groups WHERE automated_backup_preference <> 0
UNION ALL SELECT ''PriorityReplicas'', COUNT(*), NULL FROM sys.availability_replicas WHERE backup_priority > 0
UNION ALL SELECT ''RecentHistory'', COUNT(*), NULL FROM msdb.dbo.backupset WHERE backup_finish_date > DATEADD(DAY, -30, GETDATE())
UNION ALL SELECT ''PreferredSource'', COUNT(*), NULL FROM msdb.dbo.backupset AS b WHERE b.backup_finish_date > DATEADD(DAY, -30, GETDATE()) AND EXISTS (SELECT 1 FROM sys.availability_replicas AS r WHERE r.replica_server_name = b.server_name AND r.backup_priority > 0)
UNION ALL SELECT ''PrefDesc'', NULL, ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), ag.name) + ''='' + ag.automated_backup_preference_desc, ''; '') FROM sys.availability_groups AS ag), ''none'')';

    BEGIN TRY
        INSERT INTO @M (K, V, T) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadNote = ' One or more availability or history sources could not be read: ' + LEFT(ISNULL(ERROR_MESSAGE(), ''), 150) + '.';
    END CATCH;

    SELECT @AgCount = ISNULL(MAX(CASE WHEN K = 'AgCount' THEN V END), 0),
           @AgWithPref = ISNULL(MAX(CASE WHEN K = 'AgWithPref' THEN V END), 0),
           @PriorityReplicas = ISNULL(MAX(CASE WHEN K = 'PriorityReplicas' THEN V END), 0),
           @RecentHistory = ISNULL(MAX(CASE WHEN K = 'RecentHistory' THEN V END), 0),
           @PreferredSource = ISNULL(MAX(CASE WHEN K = 'PreferredSource' THEN V END), 0),
           @PrefDesc = ISNULL(MAX(CASE WHEN K = 'PrefDesc' THEN T END), 'none')
    FROM @M;

    SET @Signals = CASE WHEN @AgWithPref > 0 THEN 1 ELSE 0 END
                 + CASE WHEN @PriorityReplicas > 0 THEN 1 ELSE 0 END
                 + CASE WHEN @PreferredSource > 0 THEN 1 ELSE 0 END;

    SET @Score = CASE
        WHEN @AgCount > 0 AND @Signals = 3 THEN 3
        WHEN @AgCount > 0 AND @Signals = 2 THEN 2
        WHEN @AgCount = 0 AND @RecentHistory > 0 THEN 2
        WHEN @AgCount > 0 OR @RecentHistory > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        'Availability groups = ', @AgCount, ' (preference: ', @PrefDesc, ')',
        '; groups whose preference is not NONE = ', @AgWithPref,
        '; replicas with backup_priority > 0 = ', @PriorityReplicas,
        '; history rows in the last 30 days = ', @RecentHistory,
        ', of which ', @PreferredSource, ' were written by a prioritised replica.',
        CASE WHEN @AgCount = 0 THEN ' No availability group is present, so replica backup preference does not apply on this instance.' ELSE '' END,
        @ReadNote);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
