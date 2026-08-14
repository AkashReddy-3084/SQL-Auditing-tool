-- Checklist: Audit trail for changes to financial-relevant data
-- Scope: DATABASE
-- Scoring: 0 = No audit mechanisms found; 1 = Triggers or audit tables exist but no formal SQL Audit; 2 = SQL Server Audit configured for DML changes; 3 = SQL Server Audit configured and covers all user tables.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
DECLARE @AuditDmlCount INT = 0;
DECLARE @TriggerCount INT = 0;
DECLARE @AuditTableCount INT = 0;
DECLARE @TotalUserTables INT = 0;

SELECT @TotalUserTables = COUNT(*) FROM sys.tables WHERE type = ''U'';

IF OBJECT_ID(''sys.database_audit_specifications'') IS NOT NULL
BEGIN
    SELECT @AuditDmlCount = COUNT(*) FROM sys.database_audit_specification_details d
    JOIN sys.database_audit_specifications s ON d.database_audit_specification_id = s.database_audit_specification_id
    WHERE s.is_enabled = 1 AND d.audit_action_name IN (''UPDATE'', ''DELETE'', ''INSERT'');
END

SELECT @TriggerCount = COUNT(*) FROM sys.triggers t
JOIN sys.tables tab ON t.parent_id = tab.object_id
WHERE tab.type = ''U'' AND t.is_disabled = 0;

SELECT @AuditTableCount = COUNT(*) FROM sys.tables
WHERE name LIKE ''%Audit%'' OR name LIKE ''%Log%'' OR name LIKE ''%History%'' OR name LIKE ''%Trl%'';

DECLARE @DbScore INT = 0;
IF @AuditDmlCount > 0 AND @TotalUserTables > 0 AND @AuditDmlCount >= @TotalUserTables SET @DbScore = 3;
ELSE IF @AuditDmlCount > 0 SET @DbScore = 2;
ELSE IF @TriggerCount > 0 OR @AuditTableCount > 0 SET @DbScore = 1;
ELSE SET @DbScore = 0;

INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);
';
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