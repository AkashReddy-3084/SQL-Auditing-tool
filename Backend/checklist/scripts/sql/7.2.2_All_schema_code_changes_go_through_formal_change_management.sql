-- Checklist: All schema/code changes go through formal change management
-- Scope: DATABASE
-- Scoring: 3=Enabled DDL trigger or DDL audit; 2=Disabled trigger/audit or change metadata on >=5 objects; 1=Change metadata on 1-4 objects; 0=No evidence.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        SET @Sql = N'
        DECLARE @TriggerCount INT = 0;
        DECLARE @AuditEnabled BIT = 0;
        DECLARE @PropCount INT = 0;
        DECLARE @DisabledTrigger BIT = 0;
        DECLARE @DisabledAudit BIT = 0;
        
        SELECT @TriggerCount = COUNT(*) FROM sys.triggers WHERE parent_class = 1 AND type = ''TR'' AND is_disabled = 0;
        SELECT @DisabledTrigger = CASE WHEN EXISTS(SELECT 1 FROM sys.triggers WHERE parent_class = 1 AND type = ''TR'' AND is_disabled = 1) THEN 1 ELSE 0 END;
        
        IF OBJECT_ID(''sys.database_audit_specifications'') IS NOT NULL AND OBJECT_ID(''sys.database_audit_specification_details'') IS NOT NULL
        BEGIN
            SELECT @AuditEnabled = CASE WHEN EXISTS(
                SELECT 1 FROM sys.database_audit_specifications das
                JOIN sys.database_audit_specification_details dasd ON das.specification_id = dasd.specification_id
                WHERE das.is_state_enabled = 1 AND dasd.audit_action_id LIKE ''DDL%''
            ) THEN 1 ELSE 0 END;
            
            SELECT @DisabledAudit = CASE WHEN EXISTS(
                SELECT 1 FROM sys.database_audit_specifications das
                JOIN sys.database_audit_specification_details dasd ON das.specification_id = dasd.specification_id
                WHERE das.is_state_enabled = 0 AND dasd.audit_action_id LIKE ''DDL%''
            ) THEN 1 ELSE 0 END;
        END
        
        SELECT @PropCount = COUNT(*) FROM sys.extended_properties ep
        JOIN sys.objects o ON ep.major_id = o.object_id
        WHERE ep.name LIKE ''%change%'' OR ep.name LIKE ''%request%'' OR ep.name LIKE ''%ticket%'' OR ep.name LIKE ''%approval%'';
        
        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);
        
        IF @TriggerCount > 0 OR @AuditEnabled = 1
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''Enabled DDL trigger(s) or DDL audit specification found.'';
        END
        ELSE IF @DisabledTrigger = 1 OR @DisabledAudit = 1
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''DDL trigger or audit exists but is disabled.'';
        END
        ELSE IF @PropCount >= 5
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''Change management metadata found on '' + CAST(@PropCount AS NVARCHAR) + '' object(s).'';
        END
        ELSE IF @PropCount > 0
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = ''Limited change management metadata found on '' + CAST(@PropCount AS NVARCHAR) + '' object(s).'';
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = ''No DDL triggers, audit, or change management metadata found.'';
        END
        
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TriggerCount INT = 0;
            DECLARE @AuditEnabled BIT = 0;
            DECLARE @PropCount INT = 0;
            DECLARE @DisabledTrigger BIT = 0;
            DECLARE @DisabledAudit BIT = 0;
            
            SELECT @TriggerCount = COUNT(*) FROM sys.triggers WHERE parent_class = 1 AND type = ''TR'' AND is_disabled = 0;
            SELECT @DisabledTrigger = CASE WHEN EXISTS(SELECT 1 FROM sys.triggers WHERE parent_class = 1 AND type = ''TR'' AND is_disabled = 1) THEN 1 ELSE 0 END;
            
            IF OBJECT_ID(''sys.database_audit_specifications'') IS NOT NULL AND OBJECT_ID(''sys.database_audit_specification_details'') IS NOT NULL
            BEGIN
                SELECT @AuditEnabled = CASE WHEN EXISTS(
                    SELECT 1 FROM sys.database_audit_specifications das
                    JOIN sys.database_audit_specification_details dasd ON das.specification_id = dasd.specification_id
                    WHERE das.is_state_enabled = 1 AND dasd.audit_action_id LIKE ''DDL%''
                ) THEN 1 ELSE 0 END;
                
                SELECT @DisabledAudit = CASE WHEN EXISTS(
                    SELECT 1 FROM sys.database_audit_specifications das
                    JOIN sys.database_audit_specification_details dasd ON das.specification_id = dasd.specification_id
                    WHERE das.is_state_enabled = 0 AND dasd.audit_action_id LIKE ''DDL%''
                ) THEN 1 ELSE 0 END;
            END
            
            SELECT @PropCount = COUNT(*) FROM sys.extended_properties ep
            JOIN sys.objects o ON ep.major_id = o.object_id
            WHERE ep.name LIKE ''%change%'' OR ep.name LIKE ''%request%'' OR ep.name LIKE ''%ticket%'' OR ep.name LIKE ''%approval%'';
            
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);
            
            IF @TriggerCount > 0 OR @AuditEnabled = 1
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''Enabled DDL trigger(s) or DDL audit specification found.'';
            END
            ELSE IF @DisabledTrigger = 1 OR @DisabledAudit = 1
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''DDL trigger or audit exists but is disabled.'';
            END
            ELSE IF @PropCount >= 5
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Change management metadata found on '' + CAST(@PropCount AS NVARCHAR) + '' object(s).'';
            END
            ELSE IF @PropCount > 0
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Limited change management metadata found on '' + CAST(@PropCount AS NVARCHAR) + '' object(s).'';
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No DDL triggers, audit, or change management metadata found.'';
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation