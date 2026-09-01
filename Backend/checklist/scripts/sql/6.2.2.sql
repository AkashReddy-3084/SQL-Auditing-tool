-- Checklist: TLS enforced for data in transit (Encrypt=true; minimum TLS version set)
-- Scope: SERVER
-- Scoring: 3 = platform-enforced TLS with every observed session encrypted, or ForceEncryption = 1 with every session encrypted; 2 = platform-enforced TLS, or at least 90% of sessions encrypted; 1 = fewer than 90% of sessions encrypted; 0 = no connection evidence readable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Connection encryption evidence was not readable';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Total INT = 0;
DECLARE @Encrypted INT = 0;
DECLARE @SelfOption NVARCHAR(40) = 'unknown';
DECLARE @Force INT = -1;
DECLARE @Probe NVARCHAR(400);
DECLARE @Ratio DECIMAL(9, 4) = 0;

BEGIN TRY
    SELECT @Total = COUNT(*),
           @Encrypted = ISNULL(SUM(CASE WHEN encrypt_option = 'TRUE' THEN 1 ELSE 0 END), 0),
           @SelfOption = ISNULL(MAX(CASE WHEN session_id = @@SPID THEN CONVERT(NVARCHAR(40), encrypt_option) END), 'unknown')
    FROM sys.dm_exec_connections;
END TRY
BEGIN CATCH
    SET @Total = 0;
END CATCH

IF @Engine NOT IN (5, 8)
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @f = ISNULL(MAX(TRY_CONVERT(INT, value_data)), -1)
FROM sys.dm_server_registry
WHERE value_name = ''ForceEncryption'';';
        EXEC sys.sp_executesql @Probe, N'@f INT OUTPUT', @f = @Force OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Force = -1;
    END CATCH
END

SET @Ratio = CASE WHEN @Total = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Encrypted) / NULLIF(@Total, 0) END;

SET @Score = CASE
    WHEN @Engine IN (5, 8) AND @Total > 0 AND @Encrypted = @Total THEN 3
    WHEN @Engine IN (5, 8) THEN 2
    WHEN @Total = 0 THEN 0
    WHEN @Force = 1 AND @Encrypted = @Total THEN 3
    WHEN ISNULL(@Ratio, 0) >= 0.90 THEN 2
    ELSE 1 END;

SET @Finding = CONCAT(
    CASE WHEN @Engine = 5 THEN 'Azure SQL Database: TLS is enforced by the platform. '
         WHEN @Engine = 8 THEN 'Azure SQL Managed Instance: TLS is enforced by the platform. '
         ELSE '' END,
    'connections observed = ', @Total,
    ', with encrypt_option = TRUE = ', @Encrypted,
    ', this session encrypt_option = ', @SelfOption,
    ', ForceEncryption registry value = ',
    CASE WHEN @Force = -1 THEN 'not readable on this platform' ELSE CONVERT(NVARCHAR(10), @Force) END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
