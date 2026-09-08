SET NOCOUNT ON;

/* Checklist 6.2.1 - Transparent Data Encryption (TDE) enabled for encryption at rest.
   Read-only: queries catalog views and DMVs only. */

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT;
DECLARE @DatabaseQueried  NVARCHAR(4000);
DECLARE @Finding          NVARCHAR(MAX);
DECLARE @TotalUserDbs     INT = 0;
DECLARE @EncryptedDbs     INT = 0;
DECLARE @UnencryptedDbs   INT = 0;
DECLARE @UnencryptedList  NVARCHAR(MAX) = N'';
DECLARE @EncryptedList    NVARCHAR(MAX) = N'';

IF OBJECT_ID('tempdb..#TdeStatus') IS NOT NULL
    DROP TABLE #TdeStatus;

CREATE TABLE #TdeStatus
(
    DatabaseName        SYSNAME        NOT NULL,
    IsEncryptedFlag     BIT            NULL,
    EncryptionState     INT            NULL,
    EncryptionStateDesc NVARCHAR(100)  NOT NULL,
    EncryptorType       NVARCHAR(50)   NULL,
    KeyAlgorithm        NVARCHAR(50)   NULL,
    KeyLength           INT            NULL,
    IsTdeActive         BIT            NOT NULL
);

INSERT INTO #TdeStatus
(
    DatabaseName, IsEncryptedFlag, EncryptionState, EncryptionStateDesc,
    EncryptorType, KeyAlgorithm, KeyLength, IsTdeActive
)
SELECT
    d.name,
    d.is_encrypted,
    dek.encryption_state,
    CASE dek.encryption_state
         WHEN 0 THEN N'No database encryption key present, no encryption'
         WHEN 1 THEN N'Unencrypted'
         WHEN 2 THEN N'Encryption in progress'
         WHEN 3 THEN N'Encrypted'
         WHEN 4 THEN N'Key change in progress'
         WHEN 5 THEN N'Decryption in progress'
         WHEN 6 THEN N'Protection change in progress'
         ELSE N'No database encryption key present, no encryption'
    END,
    dek.encryptor_type,
    dek.key_algorithm,
    dek.key_length,
    CASE WHEN dek.encryption_state IN (2, 3, 4, 6) THEN 1 ELSE 0 END
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS dek
       ON dek.database_id = d.database_id
WHERE d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
  AND d.state = 0                  /* ONLINE only - offline databases cannot be inspected */
  AND d.source_database_id IS NULL /* exclude database snapshots */
  AND d.is_read_only = 0;

SELECT
    @TotalUserDbs   = COUNT(*),
    @EncryptedDbs   = SUM(CASE WHEN IsTdeActive = 1 THEN 1 ELSE 0 END),
    @UnencryptedDbs = SUM(CASE WHEN IsTdeActive = 0 THEN 1 ELSE 0 END)
FROM #TdeStatus;

SET @TotalUserDbs   = ISNULL(@TotalUserDbs, 0);
SET @EncryptedDbs   = ISNULL(@EncryptedDbs, 0);
SET @UnencryptedDbs = ISNULL(@UnencryptedDbs, 0);

SELECT @UnencryptedList = STUFF((
        SELECT N', ' + t.DatabaseName + N' (' + t.EncryptionStateDesc + N')'
        FROM #TdeStatus AS t
        WHERE t.IsTdeActive = 0
        ORDER BY t.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @EncryptedList = STUFF((
        SELECT N', ' + t.DatabaseName + N' (' + t.EncryptionStateDesc
               + N', encryptor: ' + ISNULL(t.EncryptorType, N'unknown')
               + N', algorithm: ' + ISNULL(t.KeyAlgorithm, N'unknown')
               + N'_' + ISNULL(CONVERT(NVARCHAR(20), t.KeyLength), N'?') + N')'
        FROM #TdeStatus AS t
        WHERE t.IsTdeActive = 1
        ORDER BY t.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @UnencryptedList = ISNULL(@UnencryptedList, N'none');
SET @EncryptedList   = ISNULL(@EncryptedList,   N'none');

SET @DatabaseQueried = N'SERVER: ' + CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName'))
                       + N' (all online read-write user databases, count = '
                       + CONVERT(NVARCHAR(20), @TotalUserDbs) + N')';

IF @TotalUserDbs = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No online read-write user databases were found on this instance, so no unencrypted user data is currently at rest. '
                 + N'Confirm that TDE is applied as a standard when user databases are created or restored onto this server.';
END
ELSE IF @UnencryptedDbs = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Transparent Data Encryption is enabled on all ' + CONVERT(NVARCHAR(20), @TotalUserDbs)
                 + N' user database(s). Encrypted databases: ' + @EncryptedList + N'.';
END
ELSE IF @EncryptedDbs > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Transparent Data Encryption is only partially deployed: ' + CONVERT(NVARCHAR(20), @EncryptedDbs)
                 + N' of ' + CONVERT(NVARCHAR(20), @TotalUserDbs) + N' user database(s) are encrypted. '
                 + N'Databases WITHOUT TDE: ' + @UnencryptedList + N'. '
                 + N'Databases WITH TDE: ' + @EncryptedList + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Transparent Data Encryption is not enabled on any of the ' + CONVERT(NVARCHAR(20), @TotalUserDbs)
                 + N' user database(s). Data files, log files and backups are stored unencrypted at rest. '
                 + N'Databases WITHOUT TDE: ' + @UnencryptedList + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#TdeStatus') IS NOT NULL
    DROP TABLE #TdeStatus;