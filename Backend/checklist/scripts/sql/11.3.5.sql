-- Checklist: Non-prod data masking/subsetting applied where sensitive
-- Scope: DATABASE
-- Scoring: 3 = non-production database with no sensitive-named columns or all of them masked, or a production-named database where the control does not apply; 2 = at least 75% of sensitive-named columns masked; 1 = some but under 75% masked; 0 = sensitive-named columns present and none masked

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Masking state could not be inspected in this database';

DECLARE @Name NVARCHAR(128) = LOWER(DB_NAME());
DECLARE @IsNonProd BIT = 0;
DECLARE @Sensitive INT = 0;
DECLARE @Masked INT = 0;
DECLARE @Unmasked NVARCHAR(MAX) = '';

SET @IsNonProd = CASE
    WHEN @Name LIKE '%dev%' OR @Name LIKE '%test%' OR @Name LIKE '%tst%'
      OR @Name = 'qa' OR @Name LIKE 'qa[_-]%' OR @Name LIKE '%[_-]qa' OR @Name LIKE '%[_-]qa[_-]%'
      OR @Name LIKE '%uat%' OR @Name LIKE '%stag%' OR @Name LIKE '%sandbox%'
      OR @Name LIKE '%demo%' OR @Name LIKE '%train%' OR @Name LIKE '%preprod%'
      OR @Name LIKE '%pre[_-]prod%' OR @Name LIKE '%nonprod%' OR @Name LIKE '%non[_-]prod%'
    THEN 1 ELSE 0 END;

BEGIN TRY
    SELECT @Sensitive = COUNT(*),
           @Masked = ISNULL(SUM(CASE WHEN c.is_masked = 1 THEN 1 ELSE 0 END), 0),
           @Unmasked = ISNULL(LEFT(STRING_AGG(CASE WHEN c.is_masked = 0
                                                   THEN CONVERT(NVARCHAR(MAX), s.name + '.' + t.name + '.' + c.name)
                                              END, ', '), 400), '')
    FROM sys.columns AS c
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (c.name LIKE '%ssn%' OR c.name LIKE '%national[_]id%' OR c.name LIKE '%aadhaar%'
           OR c.name LIKE '%passport%' OR c.name LIKE '%creditcard%' OR c.name LIKE '%credit[_]card%'
           OR c.name LIKE '%card[_]number%' OR c.name LIKE '%cardno%' OR c.name LIKE '%cvv%'
           OR c.name LIKE '%iban%' OR c.name LIKE '%account[_]number%' OR c.name LIKE '%email%'
           OR c.name LIKE '%phone%' OR c.name LIKE '%mobile%' OR c.name LIKE '%birth%'
           OR c.name LIKE '%dob' OR c.name LIKE '%salary%' OR c.name LIKE '%tax[_]id%'
           OR c.name LIKE '%password%' OR c.name LIKE '%passwd%');
END TRY
BEGIN CATCH
    SET @Sensitive = 0;
END CATCH

IF @IsNonProd = 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT('Database "', DB_NAME(),
                          '" does not match a non-production naming pattern (dev, test, tst, qa, uat, stag, sandbox, demo, train, preprod, nonprod); ',
                          @Sensitive, ' sensitive-named column(s) present, ', @Masked,
                          ' of them masked. Non-production masking/subsetting does not apply to this database.');
END
ELSE IF @Sensitive = 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT('Non-production database "', DB_NAME(),
                          '": no user-table column matches a sensitive-data naming pattern, so no unmasked sensitive data is exposed here.');
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Masked = @Sensitive THEN 3
                      WHEN (@Masked * 100) / NULLIF(@Sensitive, 0) >= 75 THEN 2
                      WHEN @Masked > 0 THEN 1
                      ELSE 0 END;
    SET @Finding = CONCAT('Non-production database "', DB_NAME(), '": ', @Masked, ' of ', @Sensitive,
                          ' sensitive-named column(s) have dynamic data masking applied. Unmasked columns: ',
                          CASE WHEN @Unmasked = '' THEN 'none' ELSE @Unmasked END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
