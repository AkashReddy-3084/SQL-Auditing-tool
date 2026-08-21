-- Checklist: Linked servers / external data sources use least-privilege, non-personal credentials
-- Scope: SERVER
-- Scoring: 3=All use integrated security/managed identity/service accounts; 2=<20% non-compliant; 1=20-50% non-compliant; 0=>50% non-compliant or any use sa/admin.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #Findings (
    SourceType NVARCHAR(50),
    SourceName NVARCHAR(256),
    DbName NVARCHAR(128),
    AuthType NVARCHAR(50),
    CredentialName NVARCHAR(256),
    IsCompliant BIT
);

-- Check Linked Servers
IF OBJECT_ID('sys.linked_logins') IS NOT NULL
BEGIN
    INSERT INTO #Findings
    SELECT 
        'LinkedServer',
        s.name,
        'master',
        CASE WHEN l.uses_self_credential = 1 THEN 'Integrated' ELSE 'Explicit' END,
        l.rmt_user,
        CASE 
            WHEN l.uses_self_credential = 1 THEN 1
            WHEN l.rmt_user LIKE 'svc[_]%' OR l.rmt_user LIKE 'app[_]%' OR l.rmt_user LIKE 'service[_]%' OR l.rmt_user LIKE 'managed[_]%' OR l.rmt_user LIKE 'azure[_]%' OR l.rmt_user LIKE 'aad[_]%' THEN 1
            ELSE 0
        END
    FROM sys.servers s
    LEFT JOIN sys.linked_logins l ON s.server_id = l.server_id
    WHERE s.is_linked = 1;
END

-- Check External Data Sources across user databases
IF OBJECT_ID('sys.external_data_sources') IS NOT NULL
BEGIN
    DECLARE @DbName NVARCHAR(128);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #Findings
        SELECT 
            ''ExternalDataSource'',
            eds.name,
            ''' + @DbName + N''',
            CASE WHEN c.name IS NULL THEN ''ManagedIdentity/Integrated'' ELSE ''Credential'' END,
            c.name,
            CASE 
                WHEN c.name IS NULL THEN 1
                WHEN c.name LIKE ''svc[_]%'' OR c.name LIKE ''app[_]%'' OR c.name LIKE ''service[_]%'' OR c.name LIKE ''managed[_]%'' OR c.name LIKE ''azure[_]%'' OR c.name LIKE ''aad[_]%'' THEN 1
                ELSE 0
            END
        FROM sys.external_data_sources eds
        LEFT JOIN sys.database_credentials c ON eds.credential_id = c.credential_id;';
        
        BEGIN TRY
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #Findings (SourceType, SourceName, DbName, AuthType, CredentialName, IsCompliant)
            VALUES ('ExternalDataSource', 'Error', @DbName, 'Unknown', 'Evaluation failed', 0);
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

-- Calculate scores
DECLARE @Total INT = (SELECT COUNT(*) FROM #Findings);
DECLARE @Compliant INT = (SELECT COUNT(*) FROM #Findings WHERE IsCompliant = 1);
DECLARE @NonCompliant INT = @Total - @Compliant;
DECLARE @HasHighPriv BIT = (SELECT MAX(CASE WHEN CredentialName LIKE '%sa%' OR CredentialName LIKE '%admin%' THEN 1 ELSE 0 END) FROM #Findings WHERE IsCompliant = 0);

IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No linked servers or external data sources found.';
END
ELSE
BEGIN
    IF @HasHighPriv = 1 SET @Score = 0;
    ELSE IF @NonCompliant = 0 SET @Score = 3;
    ELSE IF CAST(@NonCompliant AS FLOAT) / @Total < 0.2 SET @Score = 2;
    ELSE IF CAST(@NonCompliant AS FLOAT) / @Total < 0.5 SET @Score = 1;
    ELSE SET @Score = 0;

    DECLARE @NonCompliantList NVARCHAR(MAX) = (
        SELECT STRING_AGG(SourceType + ': ' + SourceName + ' (' + DbName + ')', ', ')
        FROM #Findings WHERE IsCompliant = 0
    );
    
    IF @NonCompliantList IS NULL SET @NonCompliantList = 'None';
    
    SET @Finding = 'Total: ' + CAST(@Total AS NVARCHAR) + ', Compliant: ' + CAST(@Compliant AS NVARCHAR) + ', Non-compliant: ' + CAST(@NonCompliant AS NVARCHAR) + '. Non-compliant: ' + @NonCompliantList;
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Findings;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;