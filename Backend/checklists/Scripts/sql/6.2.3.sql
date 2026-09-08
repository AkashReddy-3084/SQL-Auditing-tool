-- Checklist: Always Encrypted used for highly sensitive columns where required
-- Scope: DATABASE
-- Scoring: 3 = no sensitive-named columns exist, or every one is Always Encrypted; 2 = column master/encryption keys exist and under 25% of sensitive columns are unprotected; 1 = keys exist but 25% or more are unprotected; 0 = sensitive columns exist with no keys defined, or metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Always Encrypted metadata was not readable in this database';
DECLARE @Cmk INT = 0;
DECLARE @Cek INT = 0;
DECLARE @EncCols INT = 0;
DECLARE @Sensitive INT = 0;
DECLARE @Unprotected INT = 0;
DECLARE @Names NVARCHAR(MAX) = 'none';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Failed BIT = 0;
DECLARE @Cols TABLE (FullName NVARCHAR(400), IsEncrypted BIT);

BEGIN TRY
    SELECT @Cmk = COUNT(*) FROM sys.column_master_keys;
    SELECT @Cek = COUNT(*) FROM sys.column_encryption_keys;
    SELECT @EncCols = COUNT(*) FROM sys.columns WHERE encryption_type IS NOT NULL;

    INSERT INTO @Cols (FullName, IsEncrypted)
    SELECT CONCAT(s.name, '.', t.name, '.', c.name),
           CASE WHEN c.encryption_type IS NOT NULL THEN 1 ELSE 0 END
    FROM sys.columns AS c
    JOIN sys.tables AS t ON t.object_id = c.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (c.name LIKE '%ssn%' OR c.name LIKE '%socialsecurity%' OR c.name LIKE '%creditcard%'
        OR c.name LIKE '%cardnumber%' OR c.name LIKE '%cvv%' OR c.name LIKE '%passport%'
        OR c.name LIKE '%nationalid%' OR c.name LIKE '%taxid%' OR c.name LIKE '%iban%'
        OR c.name LIKE '%bankaccount%' OR c.name LIKE '%accountnumber%' OR c.name LIKE '%salary%'
        OR c.name LIKE '%password%' OR c.name LIKE '%dateofbirth%' OR c.name LIKE '%birthdate%'
        OR c.name LIKE '%diagnosis%' OR c.name LIKE '%medicalrecord%');
END TRY
BEGIN CATCH
    SET @Failed = 1;
END CATCH

SELECT @Sensitive = COUNT(*),
       @Unprotected = ISNULL(SUM(CASE WHEN IsEncrypted = 0 THEN 1 ELSE 0 END), 0)
FROM @Cols;

SELECT @Names = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), FullName), ', '), 'none')
FROM @Cols
WHERE IsEncrypted = 0;

SET @Ratio = CASE WHEN @Sensitive = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Unprotected) / NULLIF(@Sensitive, 0) END;

SET @Score = CASE
    WHEN @Failed = 1 THEN 0
    WHEN @Sensitive = 0 OR @Unprotected = 0 THEN 3
    WHEN @Cmk = 0 OR @Cek = 0 THEN 0
    WHEN ISNULL(@Ratio, 1) < 0.25 THEN 2
    ELSE 1 END;

SET @Finding = CASE
    WHEN @Failed = 1 THEN CONCAT('Always Encrypted metadata could not be read in ', @DatabaseQueried)
    ELSE CONCAT('column master keys = ', @Cmk,
                ', column encryption keys = ', @Cek,
                ', Always Encrypted columns = ', @EncCols,
                ', sensitive-named columns = ', @Sensitive,
                ', of those unprotected = ', @Unprotected,
                CASE WHEN @Unprotected = 0 THEN '' ELSE CONCAT(' (', LEFT(@Names, 400), ')') END)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
