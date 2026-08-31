-- Checklist 6.2.8 - Customer-managed keys (CMK/BYOK) used where policy requires
-- Scope: SERVER. Strictly read-only: reads encryption metadata only, no DDL/DML on user objects.
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);
DECLARE @DatabaseQueried NVARCHAR(128) = N'SERVER';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @MetadataReadable BIT = 1;

IF OBJECT_ID('tempdb..#Dek') IS NOT NULL DROP TABLE #Dek;
CREATE TABLE #Dek
(
    DatabaseName    SYSNAME       NOT NULL,
    EncryptionState INT           NULL,
    EncryptorType   NVARCHAR(64)  NULL
);

IF OBJECT_ID('tempdb..#EkmKey') IS NOT NULL DROP TABLE #EkmKey;
CREATE TABLE #EkmKey
(
    KeyName         NVARCHAR(256) NULL,
    ProviderName    NVARCHAR(256) NULL,
    ProviderEnabled BIT           NULL
);

-- Per-database TDE encryptor inventory (online, non-system databases)
BEGIN TRY
    INSERT INTO #Dek (DatabaseName, EncryptionState, EncryptorType)
    SELECT d.name,
           dek.encryption_state,
           LTRIM(RTRIM(dek.encryptor_type))
    FROM sys.databases AS d
    LEFT JOIN sys.dm_database_encryption_keys AS dek
        ON dek.database_id = d.database_id
    WHERE d.name NOT IN (N'master', N'tempdb', N'model', N'msdb')
      AND d.state = 0;
END TRY
BEGIN CATCH
    SET @MetadataReadable = 0;
END CATCH

-- Externally held (EKM / Key Vault) asymmetric keys; catalog is absent on Azure SQL Database
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT ak.name, cp.name, CAST(cp.is_enabled AS BIT)
                     FROM master.sys.asymmetric_keys AS ak
                     INNER JOIN master.sys.cryptographic_providers AS cp
                         ON ak.cryptographic_provider_id = cp.provider_id;';

        INSERT INTO #EkmKey (KeyName, ProviderName, ProviderEnabled)
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Cryptographic provider catalog unavailable on this edition or not permitted
        DELETE FROM #EkmKey;
    END CATCH
END

DECLARE @UserDbCount    INT = (SELECT COUNT(*) FROM #Dek);
DECLARE @EncryptedCount INT = (SELECT COUNT(*) FROM #Dek WHERE EncryptionState IN (2, 3));
DECLARE @CmkProtected   INT = (SELECT COUNT(*) FROM #Dek WHERE EncryptionState IN (2, 3) AND EncryptorType = N'ASYMMETRIC KEY');
DECLARE @CertProtected  INT = (SELECT COUNT(*) FROM #Dek WHERE EncryptionState IN (2, 3) AND EncryptorType = N'CERTIFICATE');
DECLARE @EkmKeyCount    INT = (SELECT COUNT(*) FROM #EkmKey);
DECLARE @EkmEnabled     INT = (SELECT COUNT(*) FROM #EkmKey WHERE ProviderEnabled = 1);

DECLARE @CmkDbList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #Dek
                  WHERE EncryptionState IN (2, 3) AND EncryptorType = N'ASYMMETRIC KEY'
                  ORDER BY DatabaseName
                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @CertDbList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #Dek
                  WHERE EncryptionState IN (2, 3) AND EncryptorType = N'CERTIFICATE'
                  ORDER BY DatabaseName
                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @ProviderList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT DISTINCT N', ' + ProviderName
                  FROM #EkmKey
                  WHERE ProviderName IS NOT NULL
                  FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');

SET @CmkDbList    = LEFT(@CmkDbList, 600);
SET @CertDbList   = LEFT(@CertDbList, 600);
SET @ProviderList = LEFT(@ProviderList, 400);

IF @IsAzureSqlDb = 1
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database detected (EngineEdition 5). ' + CAST(@EncryptedCount AS NVARCHAR(10))
                 + N' of ' + CAST(@UserDbCount AS NVARCHAR(10)) + N' user database(s) report TDE as enabled, but the TDE protector '
                 + N'(service-managed key vs customer-managed Key Vault key) is configured on the logical server and is not exposed to T-SQL. '
                 + N'Verify the TDE protector source in the Azure portal or via Get-AzSqlServerTransparentDataEncryptionProtector against the encryption policy.';
END
ELSE IF @MetadataReadable = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Encryption metadata could not be read with the current permissions (VIEW SERVER STATE / VIEW ANY DEFINITION are required for sys.dm_database_encryption_keys). '
                 + N'Customer-managed key usage could not be determined and must be verified manually.';
END
ELSE IF @UserDbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No online user databases were found on this instance, so customer-managed key (CMK/BYOK) usage could not be evaluated. '
                 + N'EKM/Key Vault-bound asymmetric keys registered: ' + CAST(@EkmKeyCount AS NVARCHAR(10)) + N' (provider(s): ' + @ProviderList + N').';
END
ELSE IF @EncryptedCount = 0 AND @EkmKeyCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'An external key store is registered (' + CAST(@EkmKeyCount AS NVARCHAR(10)) + N' asymmetric key(s) bound to EKM provider(s): '
                 + @ProviderList + N'), but none of the ' + CAST(@UserDbCount AS NVARCHAR(10))
                 + N' online user database(s) is encrypted, so no customer-managed key is actually protecting data at rest.';
END
ELSE IF @EncryptedCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No customer-managed key protects data at rest: none of the ' + CAST(@UserDbCount AS NVARCHAR(10))
                 + N' online user database(s) is encrypted and no asymmetric key is bound to an EKM/Key Vault cryptographic provider on this instance.';
END
ELSE IF @CmkProtected = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'All ' + CAST(@EncryptedCount AS NVARCHAR(10)) + N' encrypted user database(s) are protected by a service-managed CERTIFICATE encryptor, not a customer-managed key. '
                 + N'Certificate-protected database(s): ' + @CertDbList + N'. EKM/Key Vault-bound asymmetric keys registered: ' + CAST(@EkmKeyCount AS NVARCHAR(10)) + N'.';
END
ELSE IF @EkmKeyCount = 0
BEGIN
    SET @Score = 2;
    SET @Finding = CAST(@CmkProtected AS NVARCHAR(10)) + N' of ' + CAST(@EncryptedCount AS NVARCHAR(10))
                 + N' encrypted user database(s) use an ASYMMETRIC KEY encryptor (' + @CmkDbList + N'), but no asymmetric key on this instance is bound to a registered EKM/Key Vault cryptographic provider. '
                 + N'The key therefore appears to be held locally rather than in an external customer-controlled key store; confirm the key custody model against policy.';
END
ELSE IF @CertProtected > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Customer-managed keys are only partially applied: ' + CAST(@CmkProtected AS NVARCHAR(10)) + N' database(s) use an EKM-backed ASYMMETRIC KEY encryptor ('
                 + @CmkDbList + N') while ' + CAST(@CertProtected AS NVARCHAR(10)) + N' database(s) remain on a service-managed CERTIFICATE (' + @CertDbList
                 + N'). Registered EKM provider(s): ' + @ProviderList + N' (' + CAST(@EkmEnabled AS NVARCHAR(10)) + N' enabled).';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@EncryptedCount AS NVARCHAR(10)) + N' encrypted user database(s) are protected by an ASYMMETRIC KEY encryptor backed by a registered EKM/Key Vault cryptographic provider. '
                 + N'CMK-protected database(s): ' + @CmkDbList + N'. Provider(s): ' + @ProviderList + N' (' + CAST(@EkmEnabled AS NVARCHAR(10)) + N' of '
                 + CAST(@EkmKeyCount AS NVARCHAR(10)) + N' key binding(s) enabled). No database relies on a service-managed certificate.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Dek;
DROP TABLE #EkmKey;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;