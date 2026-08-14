-- Checklist: TLS enforced for data in transit (Encrypt=true; minimum TLS version set)
-- Scope: SERVER
-- Scoring: 0=Force encryption disabled & no encrypted connections; 1=Force encryption disabled but some connections encrypted; 2=Force encryption enabled (TLS version requires OS/registry verification); 3=Force encryption enabled & all active connections verified as encrypted
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ForceEncryption INT = 0;
DECLARE @EncryptedConnections INT = 0;
DECLARE @TotalConnections INT = 0;

-- Check force encryption setting (available on-prem & MI, not Azure SQL DB)
IF OBJECT_ID('sys.configurations') IS NOT NULL
BEGIN
    SELECT @ForceEncryption = CONVERT(INT, value_in_use)
    FROM sys.configurations
    WHERE name = N'force encryption';
END
ELSE
BEGIN
    -- Azure SQL DB enforces TLS at the platform level
    SET @ForceEncryption = 1;
END

-- Check active connections encryption status
SELECT @EncryptedConnections = COUNT(CASE WHEN encrypt_option = 1 THEN 1 END),
       @TotalConnections = COUNT(*)
FROM sys.dm_exec_connections;

IF @ForceEncryption = 1
BEGIN
    SET @Score = 2; -- Force encryption is on. Minimum TLS version requires OS/registry verification.
    IF @TotalConnections > 0 AND @EncryptedConnections = @TotalConnections
    BEGIN
        SET @Score = 3; -- Fully verified via T-SQL
    END
END
ELSE
BEGIN
    IF @EncryptedConnections > 0
    BEGIN
        SET @Score = 1; -- Partial evidence: some connections encrypted despite setting off
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;