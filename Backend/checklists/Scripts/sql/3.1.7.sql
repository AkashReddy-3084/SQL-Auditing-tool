-- Checklist: No hardcoded literals for environment-specific values
-- Scope: DATABASE
-- Scoring: 3 = no modules contain hardcoded environment literals; 2 = under 10%; 1 = 10%-49%; 0 = 50% or more, no modules, or evidence is unavailable
-- NOTE: Automated evidence uses module text patterns; application and orchestration configuration outside SQL Server requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Environment-literal evidence unavailable';
DECLARE @ModuleCount INT = 0;
DECLARE @EnvironmentLiteralModuleCount INT = 0;
DECLARE @DynamicEnvironmentModuleCount INT = 0;
DECLARE @LiteralPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT
        @ModuleCount = COUNT(*),
        @EnvironmentLiteralModuleCount = ISNULL(SUM(CASE
            WHEN m.definition LIKE N'%Data Source=%'
              OR m.definition LIKE N'%Server=%'
              OR m.definition LIKE N'%Initial Catalog=%'
              OR m.definition LIKE N'%C:%' THEN 1 ELSE 0 END), 0),
        @DynamicEnvironmentModuleCount = ISNULL(SUM(CASE
            WHEN m.definition LIKE N'%DB_NAME()%'
              OR m.definition LIKE N'%@@SERVERNAME%'
              OR m.definition LIKE N'%SERVERPROPERTY%' THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @LiteralPercent = CASE
    WHEN @ModuleCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @EnvironmentLiteralModuleCount / NULLIF(@ModuleCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @ModuleCount = 0 THEN 0
    WHEN @EnvironmentLiteralModuleCount = 0 THEN 3
    WHEN @LiteralPercent < 10.00 THEN 2
    WHEN @LiteralPercent < 50.00 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'modules = ', @ModuleCount,
    N'; modules with environment literals = ', @EnvironmentLiteralModuleCount,
    N'; literal percentage = ', @LiteralPercent, N'%',
    N'; modules with dynamic environment references = ', @DynamicEnvironmentModuleCount,
    CASE WHEN @ReadError = 1 THEN N'; module metadata could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
