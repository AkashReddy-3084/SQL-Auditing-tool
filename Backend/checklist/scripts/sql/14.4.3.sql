/*
    Checklist Item : 14.4.3 - Resource Governor used where workload isolation is required (where supported)
    Scope          : SERVER
    Type           : Read-only (SERVERPROPERTY + Resource Governor catalog views only)
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Edition         NVARCHAR(256)  = ISNULL(CAST(SERVERPROPERTY('Edition') AS NVARCHAR(256)), N'Unknown');
DECLARE @ProductVersion  NVARCHAR(128)  = ISNULL(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), N'Unknown');
DECLARE @DatabaseQueried NVARCHAR(256)  = N'SERVER-LEVEL';
DECLARE @Result          NVARCHAR(50)   = N'Fail';
DECLARE @Score           INT            = 0;
DECLARE @Finding         NVARCHAR(4000) = N'';

DECLARE @RgSupported     BIT            = 0;
DECLARE @ReadFailed      BIT            = 0;
DECLARE @ErrMsg          NVARCHAR(2048) = NULL;

DECLARE @IsEnabled       INT            = NULL;
DECLARE @Classifier      NVARCHAR(512)  = NULL;
DECLARE @UserPools       INT            = 0;
DECLARE @LimitedPools    INT            = 0;
DECLARE @UserGroups      INT            = 0;

CREATE TABLE #RgState
(
    IsEnabled      INT           NULL,
    ClassifierName NVARCHAR(512) NULL,
    UserPools      INT           NULL,
    LimitedPools   INT           NULL,
    UserGroups     INT           NULL
);

/* Enterprise / Developer (EngineEdition 3) and Azure SQL Managed Instance (8) expose Resource Governor. */
IF @EngineEdition IN (3, 8) OR @Edition LIKE N'Enterprise%' OR @Edition LIKE N'Developer%'
    SET @RgSupported = 1;

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    /* Azure SQL Database / Synapse / SQL Edge - Resource Governor is not exposed to the customer. */
    SET @Score   = 3;
    SET @Finding = N'NOT APPLICABLE: Resource Governor is not available on this platform (Edition: ' + @Edition
                 + N', EngineEdition: ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N', Version: ' + @ProductVersion
                 + N'). Workload isolation is provided by the service tier / elastic pool, so this control does not apply.';
END
ELSE IF @RgSupported = 0
BEGIN
    /* Standard / Web / Express - Resource Governor cannot be enabled on these editions. */
    SET @Score   = 3;
    SET @Finding = N'NOT APPLICABLE: Resource Governor is not supported on this edition (Edition: ' + @Edition
                 + N', EngineEdition: ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N', Version: ' + @ProductVersion
                 + N'). The feature requires Enterprise/Developer edition or Azure SQL Managed Instance, so this control does not apply.';
END
ELSE
BEGIN
    BEGIN TRY
        INSERT INTO #RgState (IsEnabled, ClassifierName, UserPools, LimitedPools, UserGroups)
        EXEC sp_executesql N'
SELECT
    CAST(rgc.is_enabled AS INT) AS IsEnabled,
    CASE
        WHEN ISNULL(rgc.classifier_function_id, 0) = 0 THEN NULL
        ELSE ISNULL(OBJECT_SCHEMA_NAME(rgc.classifier_function_id, DB_ID(N''master'')), N''<unknown>'')
             + N''.''
             + ISNULL(OBJECT_NAME(rgc.classifier_function_id, DB_ID(N''master'')), N''<unknown>'')
    END AS ClassifierName,
    (SELECT COUNT(*)
       FROM sys.resource_governor_resource_pools AS p
      WHERE p.name NOT IN (N''internal'', N''default'')) AS UserPools,
    (SELECT COUNT(*)
       FROM sys.resource_governor_resource_pools AS p
      WHERE p.name NOT IN (N''internal'', N''default'')
        AND (p.min_cpu_percent > 0 OR p.max_cpu_percent < 100
             OR p.min_memory_percent > 0 OR p.max_memory_percent < 100)) AS LimitedPools,
    (SELECT COUNT(*)
       FROM sys.resource_governor_workload_groups AS g
      WHERE g.name NOT IN (N''internal'', N''default'')) AS UserGroups
FROM sys.resource_governor_configuration AS rgc;';
    END TRY
    BEGIN CATCH
        SET @ReadFailed = 1;
        SET @ErrMsg = ERROR_MESSAGE();
    END CATCH;

    SELECT TOP (1)
           @IsEnabled    = s.IsEnabled,
           @Classifier   = s.ClassifierName,
           @UserPools    = ISNULL(s.UserPools, 0),
           @LimitedPools = ISNULL(s.LimitedPools, 0),
           @UserGroups   = ISNULL(s.UserGroups, 0)
      FROM #RgState AS s;

    IF @ReadFailed = 1 OR @IsEnabled IS NULL
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Resource Governor configuration could not be read on ' + @Edition
                     + N'. VIEW SERVER STATE / VIEW ANY DEFINITION may be missing. Error: '
                     + ISNULL(@ErrMsg, N'no rows returned from sys.resource_governor_configuration')
                     + N'.';
    END
    ELSE IF @IsEnabled = 1 AND @LimitedPools >= 1 AND @Classifier IS NOT NULL
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Resource Governor is ENABLED on ' + @Edition + N' with '
                     + CAST(@UserPools AS NVARCHAR(10)) + N' user-defined resource pool(s) ('
                     + CAST(@LimitedPools AS NVARCHAR(10)) + N' carrying non-default CPU/memory limits), '
                     + CAST(@UserGroups AS NVARCHAR(10)) + N' user-defined workload group(s), and classifier function '
                     + @Classifier + N'.';
    END
    ELSE IF @IsEnabled = 1 AND @LimitedPools >= 1
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Resource Governor is ENABLED on ' + @Edition + N' with '
                     + CAST(@UserPools AS NVARCHAR(10)) + N' user-defined resource pool(s) ('
                     + CAST(@LimitedPools AS NVARCHAR(10)) + N' with non-default limits) and '
                     + CAST(@UserGroups AS NVARCHAR(10)) + N' user-defined workload group(s), but NO classifier function is configured, so every session is still routed to the default workload group.';
    END
    ELSE IF @IsEnabled = 1
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Resource Governor is ENABLED on ' + @Edition + N' but no effective isolation is configured: '
                     + CAST(@UserPools AS NVARCHAR(10)) + N' user-defined resource pool(s), '
                     + CAST(@LimitedPools AS NVARCHAR(10)) + N' with non-default CPU/memory limits, '
                     + CAST(@UserGroups AS NVARCHAR(10)) + N' user-defined workload group(s), classifier function: '
                     + ISNULL(@Classifier, N'none') + N'. All workloads run under the default pool.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Resource Governor is DISABLED on ' + @Edition + N' (is_enabled = 0), with '
                     + CAST(@UserPools AS NVARCHAR(10)) + N' user-defined resource pool(s) and '
                     + CAST(@UserGroups AS NVARCHAR(10)) + N' user-defined workload group(s) defined but not in force. No workload isolation is applied; confirm whether isolation is required for the workloads hosted on this instance.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #RgState;