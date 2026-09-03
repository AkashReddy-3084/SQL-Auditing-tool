-- Checklist: Customer-managed keys (CMK/BYOK) used where policy requires
-- Scope: SERVER
-- Scoring: 3 = every encrypted database is protected by an asymmetric (EKM / key vault) key; 2 = some encrypted databases use an asymmetric key, an enabled cryptographic provider or a key-vault credential is registered, or Azure SQL Database reports encryption with the protector held on the logical server; 1 = encryption is on but every protector is a locally held certificate; 0 = no encrypted database and no external key evidence, or metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Encryption key metadata was not readable';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @EncDbs INT = 0;
DECLARE @CmkDbs INT = 0;
DECLARE @CertDbs INT = 0;
DECLARE @Providers INT = 0;
DECLARE @VaultCreds INT = 0;
DECLARE @SymKeys INT = 0;
DECLARE @Names NVARCHAR(MAX) = 'none';
DECLARE @Failed BIT = 0;
DECLARE @Probe NVARCHAR(800);

BEGIN TRY
    SELECT @EncDbs = COUNT(*),
           @CmkDbs = ISNULL(SUM(CASE WHEN encryptor_type = 'ASYMMETRIC KEY' THEN 1 ELSE 0 END), 0),
           @CertDbs = ISNULL(SUM(CASE WHEN encryptor_type = 'CERTIFICATE' THEN 1 ELSE 0 END), 0),
           @Names = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
                        CONCAT(ISNULL(DB_NAME(database_id), CONVERT(NVARCHAR(20), database_id)),
                               ' [', ISNULL(encryptor_type, 'unknown'), ']')), ', '), 'none')
    FROM sys.dm_database_encryption_keys
    WHERE encryption_state IN (2, 3);
END TRY
BEGIN CATCH
    SET @Failed = 1;
END CATCH

BEGIN TRY
    SELECT @SymKeys = COUNT(*) FROM sys.symmetric_keys WHERE name NOT LIKE '##%';
END TRY
BEGIN CATCH
    SET @SymKeys = 0;
END CATCH

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @p = ISNULL((SELECT COUNT(*) FROM sys.cryptographic_providers WHERE is_enabled = 1), 0),
       @v = ISNULL((SELECT COUNT(*) FROM sys.credentials
                    WHERE name LIKE ''%vault%'' OR credential_identity LIKE ''%vault%''), 0);';
        EXEC sys.sp_executesql @Probe, N'@p INT OUTPUT, @v INT OUTPUT',
             @p = @Providers OUTPUT, @v = @VaultCreds OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Providers = 0;
    END CATCH
END

SET @Score = CASE
    WHEN @Failed = 1 THEN 0
    WHEN @EncDbs > 0 AND @CmkDbs = @EncDbs THEN 3
    WHEN @CmkDbs > 0 OR @Providers > 0 OR @VaultCreds > 0 THEN 2
    WHEN @Engine = 5 AND @EncDbs > 0 THEN 2
    WHEN @EncDbs > 0 THEN 1
    ELSE 0 END;

SET @Finding = CASE
    WHEN @Failed = 1 THEN 'Transparent Data Encryption key metadata could not be read with the current permissions'
    ELSE CONCAT(
        CASE WHEN @Engine = 5 THEN 'Azure SQL Database: the TDE protector is held on the logical server and is not exposed to T-SQL. ' ELSE '' END,
        'encrypted databases = ', @EncDbs,
        ', protected by an asymmetric key = ', @CmkDbs,
        ', protected by a certificate = ', @CertDbs,
        ', enabled cryptographic providers = ', @Providers,
        ', key-vault credentials = ', @VaultCreds,
        ', user symmetric keys = ', @SymKeys,
        ', encryptors observed = ', LEFT(@Names, 400))
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
