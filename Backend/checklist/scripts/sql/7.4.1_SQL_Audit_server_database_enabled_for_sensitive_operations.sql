-- Checklist: SQL Audit (server/database) enabled for sensitive operations
-- Scope: SERVER
-- Scoring: 0=No audits configured; 1=Audits configured but disabled; 2=Audit enabled but specifications missing/partial; 3=Audit and specifications fully enabled.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Database-level audits only
    DECLARE @DbAuditEnabled INT = 0;
    SELECT @DbAuditEnabled = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;
    
    IF @DbAuditEnabled > 0
        SET @Score = 3;
    ELSE IF EXISTS (SELECT 1 FROM sys.database_audit_specifications)
        SET @Score = 1;
    ELSE
        SET @Score = 0;
        
    SET @Finding = CASE 
        WHEN @Score = 3 THEN 'Database audit enabled in current database.'
        WHEN @Score = 1 THEN 'Database audit configured but disabled in current database.'
        ELSE 'No database audit configured in current database.'
    END;
    SET @DatabaseQueried = DB_NAME();
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Server-level audits
    DECLARE @ServerAuditNames NVARCHAR(MAX) = '';
    SELECT @ServerAuditNames = STRING_AGG(name, ', ') FROM sys.server_audits WHERE is_state_enabled = 1;
    
    DECLARE @ServerSpecEnabled INT = 0;
    SELECT @ServerSpecEnabled = COUNT(*) FROM sys.server_audit_specifications WHERE is_state_enabled = 1;
    
    DECLARE @ServerAuditExists BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.server_audits) THEN 1 ELSE 0 END;
    DECLARE @ServerSpecExists BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.server_audit_specifications) THEN 1 ELSE 0 END;
    
    IF @ServerAuditExists = 1 AND @ServerSpecEnabled > 0
        SET @Score = 3;
    ELSE IF @ServerAuditExists = 1 AND @ServerSpecEnabled = 0 AND @ServerSpecExists = 1
        SET @Score = 2;
    ELSE IF @ServerAuditExists = 1 AND @ServerSpecExists = 1
        SET @Score = 1;
    ELSE
        SET @Score = 0;
        
    SET @Finding = CASE 
        WHEN @Score = 3 THEN 'Server audit enabled: ' + ISNULL(@ServerAuditNames, 'None') + '. Specifications enabled.'
        WHEN @Score = 2 THEN 'Server audit enabled: ' + ISNULL(@ServerAuditNames, 'None') + '. Specifications configured but disabled.'
        WHEN @Score = 1 THEN 'Server audit and specifications configured but disabled.'
        ELSE 'No server audits or specifications found.'
    END;
    SET @DatabaseQueried = 'master';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;