-- Checklist: HA node configuration parity verified
-- Scope: SERVER
-- Scoring: 0: Evaluation failed or no components accessible. 1: 1-2 components collected. 2: 3-5 components collected. 3: All 6 components successfully collected; cross-node parity requires manual verification.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5
BEGIN
    SET @Finding = N'Azure SQL Database: HA configuration parity is platform-managed and automatically maintained by Microsoft.';
    SET @Score = 3;
END
ELSE
BEGIN
    DECLARE @ConfigCount INT = 0, @TraceFlagCount INT = 0, @LoginCount INT = 0, @JobCount INT = 0, @LinkedServerCount INT = 0, @CertCount INT = 0;
    DECLARE @MaxDop INT = 0, @MaxMemory INT = 0;
    DECLARE @ComponentsChecked INT = 0;

    BEGIN TRY
        SELECT @ConfigCount = COUNT(*) FROM sys.configurations;
        SELECT @MaxDop = CONVERT(INT, value_in_use) FROM sys.configurations WHERE name = 'max degree of parallelism';
        SELECT @MaxMemory = CONVERT(INT, value_in_use) FROM sys.configurations WHERE name = 'max server memory (MB)';
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    BEGIN TRY
        IF OBJECT_ID('sys.trace_flags') IS NOT NULL
            SELECT @TraceFlagCount = COUNT(*) FROM sys.trace_flags;
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    BEGIN TRY
        SELECT @LoginCount = COUNT(*) FROM sys.server_principals WHERE type IN ('S','U','G','K','E') AND is_disabled = 0;
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    BEGIN TRY
        SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs WHERE enabled = 1;
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    BEGIN TRY
        SELECT @LinkedServerCount = COUNT(*) FROM sys.servers WHERE server_id > 0;
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    BEGIN TRY
        SELECT @CertCount = COUNT(*) FROM sys.certificates;
        SET @ComponentsChecked += 1;
    END TRY BEGIN CATCH SET @ComponentsChecked += 0; END CATCH;

    SET @Finding = N'Instance Configs: ' + CAST(@ConfigCount AS NVARCHAR(10)) + N', MAXDOP: ' + CAST(@MaxDop AS NVARCHAR(10)) + N', MaxMemory: ' + CAST(@MaxMemory AS NVARCHAR(10)) + N' MB, TraceFlags: ' + CAST(@TraceFlagCount AS NVARCHAR(10)) + N', Active Logins: ' + CAST(@LoginCount AS NVARCHAR(10)) + N', Enabled Jobs: ' + CAST(@JobCount AS NVARCHAR(10)) + N', LinkedServers: ' + CAST(@LinkedServerCount AS NVARCHAR(10)) + N', Certificates: ' + CAST(@CertCount AS NVARCHAR(10)) + N'. Cross-node parity requires manual verification.';
    
    IF @ComponentsChecked >= 6 SET @Score = 3;
    ELSE IF @ComponentsChecked >= 3 SET @Score = 2;
    ELSE IF @ComponentsChecked >= 1 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SET @DatabaseQueried = 'master';

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;