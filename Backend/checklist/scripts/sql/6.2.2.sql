/* Checklist 6.2.2 - TLS enforced for data in transit (Encrypt=true; minimum TLS version set) */
/* Read-only: reads SERVERPROPERTY, SuperSocketNetLib/SCHANNEL registry values and sys.dm_exec_connections. */
SET NOCOUNT ON;

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @ServerName      NVARCHAR(256) = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), CAST(@@SERVERNAME AS NVARCHAR(256)));
DECLARE @Result          NVARCHAR(20)   = N'Fail';
DECLARE @Score           INT            = 1;
DECLARE @Finding         NVARCHAR(4000) = N'';

DECLARE @ForceEncryption INT = NULL;
DECLARE @CertHash        NVARCHAR(256) = NULL;
DECLARE @RegAccessible   BIT = 1;

DECLARE @Tls10En INT = NULL, @Tls10Dis INT = NULL;
DECLARE @Tls11En INT = NULL, @Tls11Dis INT = NULL;
DECLARE @Tls12En INT = NULL, @Tls12Dis INT = NULL;

DECLARE @TotalConn INT = 0, @EncConn INT = 0, @ConnVisible BIT = 1;

/* Observed encryption state of the currently connected sessions. */
BEGIN TRY
    SELECT @TotalConn = COUNT(*),
           @EncConn   = SUM(CASE WHEN encrypt_option = 'TRUE' THEN 1 ELSE 0 END)
    FROM sys.dm_exec_connections;
END TRY
BEGIN CATCH
    SET @ConnVisible = 0;
    SET @TotalConn = 0;
    SET @EncConn = 0;
END CATCH

IF @EngineEdition IN (5, 6, 8, 9, 11)
BEGIN
    /* Azure SQL Database / Synapse / Managed Instance / SQL Edge: encryption in transit and the
       minimum TLS version are enforced by the platform and cannot be disabled by the tenant. */
    SET @Score = 3;
    SET @Finding = N'Azure SQL platform detected (EngineEdition '
        + CAST(@EngineEdition AS NVARCHAR(10))
        + N'). Encryption in transit is enforced by the service for all client connections and the minimum TLS version is managed by Microsoft. Observed encrypted connections: '
        + CAST(@EncConn AS NVARCHAR(10)) + N' of ' + CAST(@TotalConn AS NVARCHAR(10)) + N'.';
END
ELSE
BEGIN
    /* SQL Server network configuration: Force Encryption + certificate. */
    BEGIN TRY
        EXEC master.sys.xp_instance_regread
             N'HKEY_LOCAL_MACHINE',
             N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib',
             N'ForceEncryption',
             @ForceEncryption OUTPUT;
    END TRY
    BEGIN CATCH
        SET @RegAccessible = 0;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_instance_regread
             N'HKEY_LOCAL_MACHINE',
             N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib',
             N'Certificate',
             @CertHash OUTPUT;
    END TRY
    BEGIN CATCH
        SET @CertHash = NULL;
    END CATCH

    /* SCHANNEL server-side protocol policy. */
    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server',
             N'Enabled',
             @Tls10En OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls10En = NULL;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server',
             N'DisabledByDefault',
             @Tls10Dis OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls10Dis = NULL;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server',
             N'Enabled',
             @Tls11En OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls11En = NULL;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server',
             N'DisabledByDefault',
             @Tls11Dis OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls11Dis = NULL;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server',
             N'Enabled',
             @Tls12En OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls12En = NULL;
    END CATCH

    BEGIN TRY
        EXEC master.sys.xp_regread
             N'HKEY_LOCAL_MACHINE',
             N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server',
             N'DisabledByDefault',
             @Tls12Dis OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Tls12Dis = NULL;
    END CATCH

    /* TLS 1.2 counts as available unless it is explicitly turned off. */
    DECLARE @Tls12Ok BIT =
        CASE WHEN (@Tls12En IS NULL OR @Tls12En <> 0)
              AND (@Tls12Dis IS NULL OR @Tls12Dis = 0)
             THEN 1 ELSE 0 END;

    /* A minimum version is only "set" when the legacy protocols are explicitly disabled. */
    DECLARE @LegacyDisabled BIT =
        CASE WHEN (@Tls10En = 0 OR @Tls10Dis = 1)
              AND (@Tls11En = 0 OR @Tls11Dis = 1)
             THEN 1 ELSE 0 END;

    DECLARE @ForceOn BIT = CASE WHEN @ForceEncryption = 1 THEN 1 ELSE 0 END;

    DECLARE @RegDetail NVARCHAR(1000) =
        N'ForceEncryption=' + ISNULL(CAST(@ForceEncryption AS NVARCHAR(10)), N'(not set)')
        + N'; Certificate=' + CASE WHEN @CertHash IS NULL OR LTRIM(RTRIM(@CertHash)) = N'' THEN N'(none)' ELSE N'(configured)' END
        + N'; TLS1.0 Enabled=' + ISNULL(CAST(@Tls10En AS NVARCHAR(10)), N'(absent)')
        + N'/DisabledByDefault=' + ISNULL(CAST(@Tls10Dis AS NVARCHAR(10)), N'(absent)')
        + N'; TLS1.1 Enabled=' + ISNULL(CAST(@Tls11En AS NVARCHAR(10)), N'(absent)')
        + N'/DisabledByDefault=' + ISNULL(CAST(@Tls11Dis AS NVARCHAR(10)), N'(absent)')
        + N'; TLS1.2 Enabled=' + ISNULL(CAST(@Tls12En AS NVARCHAR(10)), N'(absent)')
        + N'/DisabledByDefault=' + ISNULL(CAST(@Tls12Dis AS NVARCHAR(10)), N'(absent)')
        + N'; encrypted connections ' + CAST(@EncConn AS NVARCHAR(10)) + N' of ' + CAST(@TotalConn AS NVARCHAR(10))
        + CASE WHEN @ConnVisible = 0 THEN N' (VIEW SERVER STATE denied)' ELSE N'' END + N'.';

    IF @RegAccessible = 0 AND @ForceEncryption IS NULL
    BEGIN
        SET @Score = 1;
        SET @Finding = N'TLS enforcement could not be verified: the SuperSocketNetLib and SCHANNEL registry values are not readable by the audit login (sysadmin required), so neither Force Encryption nor a minimum TLS version can be confirmed. ' + @RegDetail;
    END
    ELSE IF @ForceOn = 1 AND @Tls12Ok = 1 AND @LegacyDisabled = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Force Encryption is enabled on the SQL Server network configuration and a minimum TLS version is pinned: TLS 1.2 is enabled while TLS 1.0 and TLS 1.1 are explicitly disabled. ' + @RegDetail;
    END
    ELSE IF @ForceOn = 1 AND @Tls12Ok = 1 AND @LegacyDisabled = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Force Encryption is enabled so client traffic is encrypted, but no minimum TLS version is enforced - TLS 1.0 and/or TLS 1.1 are not explicitly disabled in SCHANNEL and remain negotiable. ' + @RegDetail;
    END
    ELSE IF @ForceOn = 0 AND @Tls12Ok = 1 AND @LegacyDisabled = 1
    BEGIN
        SET @Score = 2;
        SET @Finding = N'A minimum TLS version is enforced (TLS 1.2 enabled, TLS 1.0/1.1 disabled) but Force Encryption is not enabled, so clients that do not request Encrypt=true can still connect without encryption. ' + @RegDetail;
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'TLS is not enforced for data in transit: Force Encryption is not enabled and no minimum TLS version is pinned (legacy TLS 1.0/1.1 are not disabled, or TLS 1.2 is turned off). Connections can be negotiated unencrypted or over deprecated protocols. ' + @RegDetail;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result     AS Result,
       @Score      AS Score,
       @ServerName AS DatabaseQueried,
       @Finding    AS Finding;