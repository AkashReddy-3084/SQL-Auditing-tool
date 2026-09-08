-- Checklist: No shared/generic accounts for administrative or application access
-- Scope: SERVER
-- Scoring: 3 = no enabled shared/generic-named principals; 2 = such principals exist but none hold administrative roles; 1 = 1-2 hold administrative roles; 0 = 3 or more hold administrative roles, or principal metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Shared/generic account evidence could not be read on this instance';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Source NVARCHAR(60) = 'sys.server_principals';
DECLARE @Generic INT = 0;
DECLARE @Elevated INT = 0;
DECLARE @GenericList NVARCHAR(MAX) = '';
DECLARE @ElevatedList NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Pat NVARCHAR(MAX) = N'(p.name = ''sa'' OR p.name LIKE ''%shared%'' OR p.name LIKE ''%generic%''
       OR p.name LIKE ''%common%'' OR p.name LIKE ''svc[_]%'' OR p.name LIKE ''%[_]svc''
       OR p.name LIKE ''%service[_]account%'' OR p.name LIKE ''app[_]%'' OR p.name LIKE ''%[_]app''
       OR p.name LIKE ''%etl%'' OR p.name LIKE ''%admin%'' OR p.name LIKE ''%dba%''
       OR p.name LIKE ''%team%'' OR p.name LIKE ''%test%'' OR p.name LIKE ''%temp%'')';

CREATE TABLE #Generic (AccountName SYSNAME NOT NULL, IsElevated INT NOT NULL);

IF @Engine = 5
BEGIN
    SET @Source = 'sys.database_principals';
    SET @Sql = N'SELECT p.name,
                        CASE WHEN ISNULL(IS_ROLEMEMBER(''db_owner'', p.name), 0) = 1
                                  OR ISNULL(IS_ROLEMEMBER(''dbmanager'', p.name), 0) = 1
                                  OR ISNULL(IS_ROLEMEMBER(''loginmanager'', p.name), 0) = 1
                             THEN 1 ELSE 0 END
                 FROM sys.database_principals AS p
                 WHERE p.type IN (''S'',''U'',''G'',''E'',''X'')
                   AND p.principal_id > 4
                   AND p.name NOT LIKE ''##%''
                   AND ' + @Pat + N';';
END
ELSE
BEGIN
    SET @Sql = N'SELECT p.name,
                        CASE WHEN ISNULL(IS_SRVROLEMEMBER(''sysadmin'', p.name), 0) = 1
                                  OR ISNULL(IS_SRVROLEMEMBER(''securityadmin'', p.name), 0) = 1
                                  OR ISNULL(IS_SRVROLEMEMBER(''serveradmin'', p.name), 0) = 1
                             THEN 1 ELSE 0 END
                 FROM sys.server_principals AS p
                 WHERE p.type IN (''S'',''U'',''G'')
                   AND p.is_disabled = 0
                   AND p.principal_id > 1
                   AND p.name NOT LIKE ''##%''
                   AND ' + @Pat + N';';
END

BEGIN TRY
    INSERT INTO #Generic (AccountName, IsElevated) EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Principal metadata unavailable from ' + @Source + ': ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SELECT @Generic = COUNT(*),
       @Elevated = ISNULL(SUM(IsElevated), 0),
       @GenericList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), AccountName), ', '), 300), ''),
       @ElevatedList = ISNULL(LEFT(STRING_AGG(CASE WHEN IsElevated = 1 THEN CONVERT(NVARCHAR(MAX), AccountName) END, ', '), 300), '')
FROM #Generic;

SET @Generic = ISNULL(@Generic, 0);
SET @Elevated = ISNULL(@Elevated, 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @Generic = 0 THEN 3
        WHEN @Elevated = 0 THEN 2
        WHEN @Elevated <= 2 THEN 1
        ELSE 0 END;

    IF @Generic = 0
        SET @Finding = 'No enabled shared/generic-named principals found in ' + @Source
                     + ' (EngineEdition ' + CONVERT(NVARCHAR(10), @Engine) + ')';
    ELSE
        SET @Finding = CONCAT(@Source, ' (EngineEdition ', @Engine, '): ', @Generic,
            ' enabled shared/generic-named principal(s) - ', @GenericList,
            '; ', @Elevated, ' hold administrative roles',
            CASE WHEN LEN(@ElevatedList) > 0 THEN ' - ' + @ElevatedList ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
