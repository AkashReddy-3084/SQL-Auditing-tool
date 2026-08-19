-- Checklist: SQL Audit (server/database) enabled for sensitive operations
-- Scope: SERVER
-- Scoring: 3 = at least one server audit enabled; 2 = audit exists but disabled; 1 = audit specifications exist without active audit; 0 = no audit configuration found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No SQL Audit configuration found';

DECLARE @ActiveAudits INT = 0;
DECLARE @DisabledAudits INT = 0;
DECLARE @SpecsCount INT = 0;

-- Count active server audits
SELECT @ActiveAudits = COUNT(*) 
FROM sys.server_audits 
WHERE is_state_enabled = 1;

-- Count disabled server audits
SELECT @DisabledAudits = COUNT(*) 
FROM sys.server_audits 
WHERE is_state_enabled = 0;

-- Count server audit specifications
SELECT @SpecsCount = COUNT(*) 
FROM sys.server_audit_specifications;

-- Check for database audit specifications across all online user databases
-- Since scope is SERVER, we check if any DB has a specification
DECLARE @DbName NVARCHAR(255);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbSpecs INT = 0;

DECLARE db_cursor CURSOR FOR 
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'SELECT @cnt = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.database_audit_specifications';
    EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @DbSpecs OUTPUT;
    SET @SpecsCount = @SpecsCount + @DbSpecs;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

IF @ActiveAudits > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'SQL Server Audit is enabled. Active audits: ' + CAST(@ActiveAudits AS NVARCHAR(10));
END
ELSE IF @DisabledAudits > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'SQL Server Audit is configured but currently disabled. Disabled audits: ' + CAST(@DisabledAudits AS NVARCHAR(10));
END
ELSE IF @SpecsCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Audit specifications exist, but no active server audit is linked/enabled';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No SQL Server Audit objects or specifications were found';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;