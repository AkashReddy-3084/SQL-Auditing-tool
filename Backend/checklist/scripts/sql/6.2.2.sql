-- Checklist: TLS enforced for data in transit (Encrypt=true; minimum TLS version set)
-- Scope: SERVER
-- Scoring: 0: force encryption OFF; 1: force encryption ON but TLS version < 1.2 or unverifiable; 2: force encryption ON, TLS 1.2+ observed but OS-level minimum version config cannot be fully verified via T-SQL; 3: force encryption ON, TLS 1.2+ verified on all active connections or platform-enforced.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @ForceEncryption INT = 0;
DECLARE @MinTLSVersion INT = 0;
DECLARE @HasTLSColumn BIT = 0;
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

-- Check if tls_version column exists in sys.dm_exec_connections (SQL 2022+)
IF COL_LENGTH('sys.dm_exec_connections', 'tls_version') IS NOT NULL
    SET @HasTLSColumn = 1;

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database enforces TLS encryption for all connections by default. Minimum TLS version is managed by the platform.';
END
ELSE
BEGIN
    -- Check force encryption setting
    SELECT @ForceEncryption = ISNULL(value_in_use, 0)
    FROM sys.configurations
    WHERE name = 'force encryption';

    IF @ForceEncryption = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'force encryption = OFF. TLS is not enforced for data in transit.';
    END
    ELSE
    BEGIN
        -- Force encryption is ON
        IF @HasTLSColumn = 1
        BEGIN
            -- Check active connections for TLS version
            SELECT @MinTLSVersion = MIN(tls_version)
            FROM sys.dm_exec_connections
            WHERE encrypt_option = 1;

            IF @MinTLSVersion IS NULL
            BEGIN
                SET @Score = 2;
                SET @Finding = 'force encryption = ON. No active encrypted connections to verify TLS version. -- NOTE: This script provides automated evidence. Full compliance requires human review.';
            END
            ELSE IF @MinTLSVersion >= 12
            BEGIN
                SET @Score = 3;
                SET @Finding = 'force encryption = ON. All active encrypted connections use TLS 1.2 or higher.';
            END
            ELSE
            BEGIN
                SET @Score = 1;
                SET @Finding = 'force encryption = ON. Some connections use TLS versions below 1.2. Minimum TLS version should be updated.';
            END
        END
        ELSE
        BEGIN
            -- Older SQL Server, cannot check TLS version directly
            SET @Score = 2;
            SET @Finding = 'force encryption = ON. TLS version verification requires SQL Server 2022+ or OS-level registry inspection. -- NOTE: This script provides automated evidence. Full compliance requires human review.';
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;