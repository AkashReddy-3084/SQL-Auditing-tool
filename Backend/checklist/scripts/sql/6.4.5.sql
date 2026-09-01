-- Checklist: Linked servers / external data sources use least-privilege, non-personal credentials
-- Scope: SERVER
-- Scoring: 3 = no linked servers/external data sources exist, or none of their credential mappings impersonate the caller or use a personal/sa identity; 2 = under 25% of mappings are weak; 1 = under 60% are weak; 0 = 60% or more are weak, or no credential evidence could be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No linked server or external data source credential evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Linked INT = 0;
DECLARE @Maps INT = 0;
DECLARE @Weak INT = 0;
DECLARE @Cred INT = 0;
DECLARE @CredPersonal INT = 0;
DECLARE @Eds INT = 0;
DECLARE @Dsc INT = 0;
DECLARE @DscPersonal INT = 0;
DECLARE @Names NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @l = COUNT(*),
       @n = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), name), '', ''), 300), '''')
FROM sys.servers
WHERE is_linked = 1;
SELECT @m = COUNT(*),
       @w = ISNULL(SUM(CASE WHEN ll.remote_name IS NULL
                              OR ll.uses_self_credential = 1
                              OR ll.remote_name = ''sa''
                              OR CHARINDEX(CHAR(92), ll.remote_name) > 0
                              OR CHARINDEX(CHAR(64), ll.remote_name) > 0
                            THEN 1 ELSE 0 END), 0)
FROM sys.linked_logins AS ll
JOIN sys.servers AS s ON s.server_id = ll.server_id
WHERE s.is_linked = 1;
SELECT @c = COUNT(*),
       @cp = ISNULL(SUM(CASE WHEN CHARINDEX(CHAR(92), credential_identity) > 0
                               OR CHARINDEX(CHAR(64), credential_identity) > 0
                             THEN 1 ELSE 0 END), 0)
FROM sys.credentials;';

        EXEC sys.sp_executesql @Sql,
             N'@l INT OUTPUT, @n NVARCHAR(MAX) OUTPUT, @m INT OUTPUT, @w INT OUTPUT, @c INT OUTPUT, @cp INT OUTPUT',
             @l = @Linked OUTPUT, @n = @Names OUTPUT, @m = @Maps OUTPUT,
             @w = @Weak OUTPUT, @c = @Cred OUTPUT, @cp = @CredPersonal OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

BEGIN TRY
    SELECT @Eds = COUNT(*) FROM sys.external_data_sources;
END TRY
BEGIN CATCH
    SET @Err = 1;
END CATCH

BEGIN TRY
    SELECT @Dsc = COUNT(*),
           @DscPersonal = ISNULL(SUM(CASE WHEN CHARINDEX(CHAR(92), credential_identity) > 0
                                            OR CHARINDEX(CHAR(64), credential_identity) > 0
                                          THEN 1 ELSE 0 END), 0)
    FROM sys.database_scoped_credentials;
END TRY
BEGIN CATCH
    SET @Err = 1;
END CATCH

DECLARE @Total INT = ISNULL(@Maps, 0) + ISNULL(@Cred, 0) + ISNULL(@Dsc, 0);
DECLARE @Bad INT = ISNULL(@Weak, 0) + ISNULL(@CredPersonal, 0) + ISNULL(@DscPersonal, 0);

SET @Score = CASE
    WHEN @Err = 1 AND @Total = 0 AND @Eds = 0 THEN 0
    WHEN @Bad = 0 THEN 3
    WHEN CONVERT(DECIMAL(9, 4), @Bad) / NULLIF(@Total, 0) < 0.25 THEN 2
    WHEN CONVERT(DECIMAL(9, 4), @Bad) / NULLIF(@Total, 0) < 0.60 THEN 1
    ELSE 0 END;

SET @Finding = CONCAT(
    'Linked servers = ', @Linked,
    CASE WHEN LEN(@Names) > 0 THEN ' (' + @Names + ')' ELSE '' END,
    '; linked-login mappings = ', @Maps,
    ', of which impersonate the caller or use a personal/sa identity = ', @Weak,
    '; external data sources = ', @Eds,
    '; database-scoped credentials = ', @Dsc, ' (personal-looking identity = ', @DscPersonal, ')',
    '; server credentials = ', @Cred, ' (personal-looking identity = ', @CredPersonal, ')',
    CASE WHEN @Err = 1 THEN '; one or more credential sources were not readable on this platform' ELSE '' END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;