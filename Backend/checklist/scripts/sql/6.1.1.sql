SET NOCOUNT ON;

DECLARE @EntraPrincipalCount int = 0;
DECLARE @EnabledSqlLoginCount int = 0;
DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(2000);

SELECT @EntraPrincipalCount = COUNT(*)
FROM sys.server_principals
WHERE type IN ('E', 'X')
  AND name NOT LIKE N'##%';

SELECT @EnabledSqlLoginCount = COUNT(*)
FROM sys.server_principals
WHERE type = 'S'
  AND is_disabled = 0
  AND principal_id > 1
  AND name NOT LIKE N'##%';

SET @Score = CASE
    WHEN @EntraPrincipalCount > 0 AND @EnabledSqlLoginCount = 0 THEN 3
    WHEN @EntraPrincipalCount > 0 AND @EnabledSqlLoginCount > 0 THEN 2
    WHEN @EntraPrincipalCount = 0 AND @EnabledSqlLoginCount = 0 THEN 1
    ELSE 0
END;

SET @Result = CASE
    WHEN @Score = 3 THEN N'Pass'
    WHEN @Score IN (1, 2) THEN N'Partial'
    ELSE N'Fail'
END;

SET @Finding = CONCAT(
    N'Microsoft Entra server principals: ', @EntraPrincipalCount,
    N'; enabled user-created SQL logins: ', @EnabledSqlLoginCount,
    N'. ',
    CASE @Score
        WHEN 3 THEN N'Entra authentication is configured and no enabled user-created SQL logins were found.'
        WHEN 2 THEN N'Entra authentication is configured, but enabled user-created SQL logins remain available.'
        WHEN 1 THEN N'No enabled user-created SQL logins were found, but no Entra server principals were visible.'
        ELSE N'Enabled user-created SQL logins were found and no Entra server principals were visible.'
    END
);

SELECT
    @Result AS Result,
    @Score AS Score,
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS DatabaseQueried,
    @Finding AS Finding;