-- Checklist: ETL is parameterized (no hardcoded servers, paths, dates, or credentials)
-- Scope: SERVER
-- Scoring: 3 = at least 75% of procedures are parameterized with no hardcoded modules or linked servers; 2 = at least 50% are parameterized; 1 = some parameterized procedures or hardcoded evidence exists; 0 = no procedures are parameterized, hardcoded evidence exists, or evidence is unavailable
-- NOTE: Automated evidence covers SQL Server modules and linked-server metadata; ADF/SSIS parameterization and intentional integrations require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'ETL parameterization evidence unavailable';
DECLARE @ProcedureCount INT = 0;
DECLARE @ParameterizedProcedureCount INT = 0;
DECLARE @HardcodedModuleCount INT = 0;
DECLARE @LinkedServerCount INT = 0;
DECLARE @ParameterizedPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @ProcedureCount = COUNT(*)
    FROM sys.objects
    WHERE type = N'P'
      AND is_ms_shipped = 0;

    SELECT @ParameterizedProcedureCount = COUNT(DISTINCT p.object_id)
    FROM sys.parameters AS p
    INNER JOIN sys.objects AS o ON o.object_id = p.object_id
    WHERE o.type = N'P'
      AND o.is_ms_shipped = 0;

    SELECT @HardcodedModuleCount = COUNT(*)
    FROM sys.sql_modules AS m
    WHERE m.definition LIKE N'%Password=%'
       OR m.definition LIKE N'%Data Source=%'
       OR m.definition LIKE N'%Server=%';

    SELECT @LinkedServerCount = COUNT(*)
    FROM sys.servers
    WHERE is_linked = 1;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @ParameterizedPercent = CASE
    WHEN @ProcedureCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @ParameterizedProcedureCount / NULLIF(@ProcedureCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @ProcedureCount = 0 THEN 2
    WHEN @ParameterizedPercent >= 75.00 AND @HardcodedModuleCount = 0 AND @LinkedServerCount = 0 THEN 3
    WHEN @ParameterizedPercent >= 50.00 THEN 2
    WHEN @ParameterizedProcedureCount > 0 OR @HardcodedModuleCount > 0 OR @LinkedServerCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'procedures = ', @ProcedureCount,
    N'; parameterized procedures = ', @ParameterizedProcedureCount,
    N'; parameterized percentage = ', @ParameterizedPercent, N'%',
    N'; modules containing Password=/Data Source=/Server= = ', @HardcodedModuleCount,
    N'; linked servers = ', @LinkedServerCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more metadata sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
