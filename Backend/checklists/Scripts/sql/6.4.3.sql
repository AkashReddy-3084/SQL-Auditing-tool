-- Checklist: Managed Identity used for service-to-service auth where supported
-- Scope: SERVER
-- Scoring: 3 = credentials exist and every one authenticates with a Managed Identity; 2 = at least half of the credentials use a Managed Identity, or no credential exists while Entra (external) principals are provisioned; 1 = credentials or external principals exist but under half use a Managed Identity; 0 = no Managed Identity, no external principal and no credential evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No credential or external identity evidence was readable';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Creds INT = 0;
DECLARE @MiCreds INT = 0;
DECLARE @DbCreds INT = 0;
DECLARE @DbMiCreds INT = 0;
DECLARE @ExtPrincipals INT = 0;
DECLARE @ExtDataSources INT = 0;
DECLARE @MiNames NVARCHAR(MAX) = 'none';
DECLARE @Total INT = 0;
DECLARE @Mi INT = 0;
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Probe NVARCHAR(1200);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @c = COUNT(*),
       @m = ISNULL(SUM(CASE WHEN c.credential_identity LIKE N''%Managed%Identity%'' THEN 1 ELSE 0 END), 0),
       @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX),
                CASE WHEN c.credential_identity LIKE N''%Managed%Identity%'' THEN c.name END), N'', ''), N''none'')
FROM sys.credentials AS c;';
        EXEC sys.sp_executesql @Probe, N'@c INT OUTPUT, @m INT OUTPUT, @n NVARCHAR(MAX) OUTPUT',
             @c = @Creds OUTPUT, @m = @MiCreds OUTPUT, @n = @MiNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Creds = 0;
    END CATCH
END

BEGIN TRY
    SELECT @DbCreds = COUNT(*),
           @DbMiCreds = ISNULL(SUM(CASE WHEN credential_identity LIKE '%Managed%Identity%' THEN 1 ELSE 0 END), 0)
    FROM sys.database_scoped_credentials;
END TRY
BEGIN CATCH
    SET @DbCreds = 0;
END CATCH

BEGIN TRY
    SELECT @ExtDataSources = COUNT(*) FROM sys.external_data_sources;
END TRY
BEGIN CATCH
    SET @ExtDataSources = 0;
END CATCH

BEGIN TRY
    SELECT @ExtPrincipals = COUNT(*) FROM sys.server_principals WHERE type IN ('E', 'X');
END TRY
BEGIN CATCH
    SET @ExtPrincipals = 0;
END CATCH

SET @Total = @Creds + @DbCreds;
SET @Mi = @MiCreds + @DbMiCreds;
SET @Ratio = CASE WHEN @Total = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Mi) / NULLIF(@Total, 0) END;

SET @Score = CASE
    WHEN @Total > 0 AND @Mi = @Total THEN 3
    WHEN @Mi > 0 AND ISNULL(@Ratio, 0) >= 0.50 THEN 2
    WHEN @Total = 0 AND @ExtPrincipals > 0 THEN 2
    WHEN @Mi > 0 OR @ExtPrincipals > 0 THEN 1
    ELSE 0 END;

SET @Finding = CONCAT(
    'server credentials = ', @Creds, ' (Managed Identity = ', @MiCreds, ')',
    ', database scoped credentials = ', @DbCreds, ' (Managed Identity = ', @DbMiCreds, ')',
    ', external data sources = ', @ExtDataSources,
    ', Entra (external) server principals = ', @ExtPrincipals,
    ', Managed Identity credentials named: ', LEFT(@MiNames, 400));

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
