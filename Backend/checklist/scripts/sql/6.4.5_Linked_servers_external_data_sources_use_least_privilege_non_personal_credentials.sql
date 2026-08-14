-- Checklist: Linked servers / external data sources use least-privilege, non-personal credentials
-- Scope: SERVER
-- Scoring: 0=Any uses personal/admin credentials or uses_self_credential; 1=Mixed compliance; 2=All use non-personal credentials; 3=All use explicit service accounts with uses_self_credential=0 and strict naming conventions.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Total INT = 0;
DECLARE @FailCount INT = 0;

CREATE TABLE #Findings (
    SourceType NVARCHAR(20),
    SourceName NVARCHAR(256),
    CredentialInfo NVARCHAR(256),
    IsPersonal BIT,
    UsesSelfCred BIT
);

-- Check Linked Servers
INSERT INTO #Findings
SELECT 'LinkedServer', s.name, 
       ISNULL(p.name, 'CurrentUser'),
       CASE WHEN ll.local_principal_id IS NULL THEN 1
            WHEN p.name LIKE '%admin%' OR p.name LIKE '%sa%' OR p.name LIKE '%user%' OR p.name LIKE '%dev%' OR p.name LIKE '%test%' OR p.name LIKE '%john%' OR p.name LIKE '%jane%' THEN 1
            ELSE 0 END,
       CASE WHEN ll.local_principal_id IS NULL THEN 1 ELSE ll.uses_self_credential END
FROM sys.servers s
LEFT JOIN sys.linked_logins ll ON s.server_id = ll.server_id
LEFT JOIN sys.server_principals p ON ll.local_principal_id = p.principal_id
WHERE s.is_linked = 1;

-- Check External Data Sources per database
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
    INSERT INTO #Findings
    SELECT ''ExternalDataSource'', eds.name, 
           ISNULL(dc.name, ''CurrentUser''),
           CASE WHEN dc.credential_id IS NULL THEN 1
                WHEN dc.name LIKE ''%admin%'' OR dc.name LIKE ''%sa%'' OR dc.name LIKE ''%user%'' OR dc.name LIKE ''%dev%'' OR dc.name LIKE ''%test%'' OR dc.name LIKE ''%john%'' OR dc.name LIKE ''%jane%'' THEN 1
                ELSE 0 END,
           CASE WHEN dc.credential_id IS NULL THEN 1 ELSE 0 END
    FROM sys.external_data_sources eds
    LEFT JOIN sys.database_credentials dc ON eds.credential_id = dc.credential_id;';
    BEGIN TRY
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Ignore errors for inaccessible databases or missing catalog views
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @Total = COUNT(*), 
       @FailCount = SUM(CASE WHEN IsPersonal = 1 OR UsesSelfCred = 1 THEN 1 ELSE 0 END) 
FROM #Findings;

IF @Total = 0
    SET @Score = 3;
ELSE BEGIN
    IF @FailCount > 0
        SET @Score = 0;
    ELSE BEGIN
        SET @Score = 2;
        -- Upgrade to 3 if all credentials use strict service account naming conventions
        IF NOT EXISTS (SELECT 1 FROM #Findings WHERE CredentialInfo NOT LIKE 'svc_%')
            SET @Score = 3;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;
DROP TABLE #Findings;