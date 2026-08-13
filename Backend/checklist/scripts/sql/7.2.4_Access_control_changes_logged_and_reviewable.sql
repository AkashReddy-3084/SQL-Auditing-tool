DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ActiveAuditCount INT = 0;
DECLARE @CoveredGroups INT = 0;

-- Check if any server audit is enabled
SELECT @ActiveAuditCount = COUNT(*) FROM sys.server_audits WHERE is_state_enabled = 1;

IF @ActiveAuditCount > 0
BEGIN
    -- Temp table to collect action groups from both server and database scopes
    CREATE TABLE #AuditGroups (action_group_name NVARCHAR(128));

    -- Collect server-level audit specification groups
    INSERT INTO #AuditGroups
    SELECT action_group_name FROM sys.server_audit_specifications WHERE is_enabled = 1;

    -- Collect database-level audit specification groups across all online user databases
    DECLARE @DBName NVARCHAR(128);
    DECLARE @SQL NVARCHAR(MAX);
    DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DBName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = N'INSERT INTO #AuditGroups SELECT action_group_name FROM ' + QUOTENAME(@DBName) + N'.sys.database_audit_specifications WHERE is_enabled = 1;';
        EXEC sp_executesql @SQL;
        FETCH NEXT FROM db_cursor INTO @DBName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Count how many of the 4 key access control groups are covered
    SELECT @CoveredGroups = COUNT(DISTINCT action_group_name)
    FROM #AuditGroups
    WHERE action_group_name IN (
        'SERVER_PRINCIPAL_CHANGE_GROUP',
        'SERVER_ROLE_MEMBER_CHANGE_GROUP',
        'DATABASE_PRINCIPAL_CHANGE_GROUP',
        'DATABASE_ROLE_MEMBER_CHANGE_GROUP'
    );

    DROP TABLE #AuditGroups;

    -- Apply scoring logic per checklist definition
    IF @CoveredGroups <= 1 SET @Score = 1;
    ELSE IF @CoveredGroups <= 3 SET @Score = 2;
    ELSE SET @Score = 3;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;