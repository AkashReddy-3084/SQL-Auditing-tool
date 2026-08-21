-- Checklist: Resource Governor used where workload isolation is required (where supported)
-- Scope: SERVER
-- Scoring: 
-- 0: Resource Governor is disabled.
-- 1: Resource Governor is enabled but no classifier function is assigned.
-- 2: Resource Governor is enabled with a classifier function, but no custom workload groups or external resource pools are configured.
-- 3: Resource Governor is enabled, classifier function assigned, and at least one custom workload group or external resource pool is configured.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @IsEnabled INT;
DECLARE @ClassifierFuncId INT;
DECLARE @CustomGroups INT;
DECLARE @CustomPools INT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Resource Governor is not supported in Azure SQL Database. Check marked as Pass per "where supported" clause.';
END
ELSE IF OBJECT_ID('sys.resource_governor_configuration') IS NOT NULL
BEGIN
    SELECT 
        @IsEnabled = is_enabled,
        @ClassifierFuncId = classifier_function_id
    FROM sys.resource_governor_configuration;

    SELECT @CustomGroups = COUNT(*) 
    FROM sys.resource_governor_workload_groups 
    WHERE name NOT IN ('default');

    SELECT @CustomPools = COUNT(*) 
    FROM sys.resource_governor_external_resource_pools 
    WHERE name NOT IN ('default');

    IF @IsEnabled = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Resource Governor is disabled.';
    END
    ELSE IF @ClassifierFuncId IS NULL
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Resource Governor is enabled but no classifier function is assigned.';
    END
    ELSE IF @CustomGroups = 0 AND @CustomPools = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Resource Governor is enabled with a classifier function, but no custom workload groups or external resource pools are configured.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Resource Governor is fully configured with classifier function, ' + CAST(@CustomGroups AS NVARCHAR(10)) + ' custom workload group(s), and ' + CAST(@CustomPools AS NVARCHAR(10)) + ' custom external resource pool(s).';
    END
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'Resource Governor metadata views are unavailable on this platform/version. Partial credit assigned.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;