-- Checklist: Data access to sensitive tables auditable (who accessed what, when)
-- Scope: DATABASE
-- Scoring: 0=No server audit enabled; 1=Server audit enabled but no DML audit on tables; 2=DML audit covers 1-3 actions on tables; 3=DML audit covers all 4 actions (SELECT, INSERT, UPDATE, DELETE) on tables
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @ServerAuditEnabled INT = 0;
IF EXISTS (SELECT 1 FROM master.sys.server_audit WHERE is_state_enabled = 1)
    SET @ServerAuditEnabled = 1;

DECLARE @DmlActionsCovered INT = 0;
IF OBJECT_ID(''sys.database_audit_specification_details'') IS NOT NULL
BEGIN
    SELECT @DmlActionsCovered = COUNT(DISTINCT aa.action_name)
    FROM sys.database_audit_specification_details ads
    JOIN sys.tables t ON ads.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.dm_audit_actions aa ON ads.audit_action_id = aa.action_id
    WHERE aa.action_name IN (''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'')
    AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');
END

INSERT INTO #DbResults (DbName, DbScore)
VALUES (DB_NAME(), CASE
    WHEN @ServerAuditEnabled = 0 THEN 0
    WHEN @DmlActionsCovered = 0 THEN 1
    WHEN @DmlActionsCovered < 4 THEN 2
    ELSE 3
END);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;