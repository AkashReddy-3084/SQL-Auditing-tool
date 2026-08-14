-- Checklist: Schema/object-level permissions align with least privilege
-- Scope: DATABASE
-- Scoring: 0=Fail (>5 broad grants), 1=Partial Pass (1-5 broad grants), 2=Mostly Pass (0 broad grants), 3=Pass (requires human review, script caps at 2)
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
        DECLARE @Violations INT = 0;
        SELECT @Violations = COUNT(*)
        FROM sys.database_permissions dp
        JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
        WHERE dp.major_id > 0
          AND dp.class IN (1, 3)
          AND dp.state IN (''G'', ''W'')
          AND p.name IN (''public'', ''db_owner'', ''db_ddladmin'')
          AND dp.permission_name IN (''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'', ''EXECUTE'', ''ALTER'', ''CONTROL'', ''REFERENCES'');
        
        INSERT INTO #DbResults
        SELECT ''' + REPLACE(@DbName, '''', '''''') + ''',
               CASE WHEN @Violations = 0 THEN 2
                    WHEN @Violations <= 5 THEN 1
                    ELSE 0 END;';
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