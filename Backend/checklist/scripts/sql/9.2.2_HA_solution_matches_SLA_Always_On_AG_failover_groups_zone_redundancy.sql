-- Checklist: HA solution matches SLA (Always On AG / failover groups / zone redundancy)
-- Scope: SERVER
-- Scoring: 0: No HA configured or completely unhealthy. 1: HA detected but degraded/partially configured. 2: HA configured and healthy, but SLA alignment requires manual verification. 3: HA fully configured, healthy, and meets standard high-availability criteria.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AgCount INT = 0;
DECLARE @HealthyReplicas INT = 0;
DECLARE @ZoneRedundant BIT = 0;
DECLARE @FailoverGroupConfigured BIT = 0;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

SET @DatabaseQueried = 'master';

-- Platform-specific HA evaluation
IF @EngineEdition <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @AgCount = COUNT(*) FROM sys.availability_groups;
                     SELECT @HealthyReplicas = COUNT(*) FROM sys.dm_hadr_availability_group_states ags
                     JOIN sys.availability_replicas ar ON ags.group_id = ar.group_id
                     WHERE ags.role = 1 AND ar.availability_mode = 1;';
        EXEC sp_executesql @Sql, N'@AgCount INT OUTPUT, @HealthyReplicas INT OUTPUT', @AgCount OUTPUT, @HealthyReplicas OUTPUT;
    END TRY
    BEGIN CATCH
        SET @AgCount = 0;
        SET @HealthyReplicas = 0;
    END CATCH
END
ELSE
BEGIN
    SELECT @ZoneRedundant = MAX(CAST(is_zone_redundant AS BIT)),
           @FailoverGroupConfigured = MAX(CASE WHEN failover_group_name IS NOT NULL THEN 1 ELSE 0 END)
    FROM sys.database_service_objectives;
END

-- Determine Score and Finding
IF @EngineEdition = 5
BEGIN
    IF @ZoneRedundant = 1 AND @FailoverGroupConfigured = 1
        SET @Score = 3;
    ELSE IF @ZoneRedundant = 1 OR @FailoverGroupConfigured = 1
        SET @Score = 2;
    ELSE
        SET @Score = 0;

    SET @Finding = 'Azure SQL DB: Zone Redundancy = ' + CAST(@ZoneRedundant AS NVARCHAR(1)) + ', Failover Group = ' + CAST(@FailoverGroupConfigured AS NVARCHAR(1));
END
ELSE
BEGIN
    IF @AgCount > 0 AND @HealthyReplicas >= 2
        SET @Score = 3;
    ELSE IF @AgCount > 0 AND @HealthyReplicas >= 1
        SET @Score = 2;
    ELSE IF @AgCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = 'SQL Server/MI: Always On AGs = ' + CAST(@AgCount AS NVARCHAR(10)) + ', Healthy Synchronous Replicas = ' + CAST(@HealthyReplicas AS NVARCHAR(10));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = @Finding + CHAR(13) + CHAR(10) + '-- NOTE: This script provides automated evidence. Full compliance requires human review.';

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;