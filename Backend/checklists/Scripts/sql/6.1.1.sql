-- Checklist: Microsoft Entra ID (Azure AD) authentication used where possible (over SQL auth)
-- Scope: SERVER
-- Scoring: 3 = Entra principals present and no enabled SQL logins; 2 = Entra present and SQL logins under 50% of principals, or integrated Windows auth only; 1 = Entra or Windows principals present but SQL logins dominate; 0 = only SQL authentication, or principal metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Authentication principals could not be read on this instance';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Entra INT = 0;
DECLARE @Windows INT = 0;
DECLARE @SqlAuth INT = 0;
DECLARE @Source NVARCHAR(60) = 'sys.server_principals';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Probe INT = 1;

IF @Engine = 5
BEGIN
    SET @Source = 'sys.database_principals';
    SET @Sql = N'SELECT @e = SUM(CASE WHEN p.type IN (''E'',''X'') THEN 1 ELSE 0 END),
                        @w = SUM(CASE WHEN p.type IN (''U'',''G'') THEN 1 ELSE 0 END),
                        @s = SUM(CASE WHEN p.type = ''S'' THEN 1 ELSE 0 END)
                 FROM sys.database_principals AS p
                 WHERE p.principal_id > 4 AND p.sid IS NOT NULL AND p.name NOT LIKE ''##%'';';
END
ELSE
BEGIN
    SET @Sql = N'SELECT @e = SUM(CASE WHEN p.type IN (''E'',''X'') THEN 1 ELSE 0 END),
                        @w = SUM(CASE WHEN p.type IN (''U'',''G'') THEN 1 ELSE 0 END),
                        @s = SUM(CASE WHEN p.type = ''S'' AND p.is_disabled = 0 THEN 1 ELSE 0 END)
                 FROM sys.server_principals AS p
                 WHERE p.principal_id > 1 AND p.name NOT LIKE ''##%'';';
END

BEGIN TRY
    EXEC sys.sp_executesql @Sql,
         N'@e INT OUTPUT, @w INT OUTPUT, @s INT OUTPUT',
         @e = @Entra OUTPUT, @w = @Windows OUTPUT, @s = @SqlAuth OUTPUT;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Principal metadata unavailable from ' + @Source + ': ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SET @Entra = ISNULL(@Entra, 0);
SET @Windows = ISNULL(@Windows, 0);
SET @SqlAuth = ISNULL(@SqlAuth, 0);

DECLARE @Total INT = @Entra + @Windows + @SqlAuth;
DECLARE @SqlPct DECIMAL(9,2) = ISNULL(100.0 * @SqlAuth / NULLIF(@Total, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @Entra > 0 AND @SqlAuth = 0 THEN 3
        WHEN (@Entra > 0 AND @SqlPct < 50) OR (@Windows > 0 AND @SqlAuth = 0) THEN 2
        WHEN @Entra > 0 OR @Windows > 0 THEN 1
        ELSE 0 END;

    IF @Total = 0
        SET @Finding = 'No user-created principals found in ' + @Source
                     + ' (EngineEdition ' + CONVERT(NVARCHAR(10), @Engine) + '); authentication model cannot be confirmed';
    ELSE
        SET @Finding = CONCAT(@Source, ' (EngineEdition ', @Engine, '): ', @Entra,
            ' Microsoft Entra principal(s), ', @Windows, ' Windows principal(s), ', @SqlAuth,
            ' enabled SQL-authentication principal(s) of ', @Total, ' total - SQL auth share ',
            CONVERT(NVARCHAR(10), @SqlPct), '%');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
