-- Checklist: Database roles used for permission grants (not per-user grants)
-- Scope: DATABASE
-- Scoring: 3=Zero direct user grants; 2=1-5 direct user grants; 1=6-20 direct user grants; 0=>20 direct user grants
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
        DECLARE @DirectUserGrants INT;
        SELECT @DirectUserGrants = COUNT(*)
        FROM sys.database_permissions dp
        JOIN sys.database_principals dp2 ON dp.grantee_principal_id = dp2.principal_id
        WHERE dp2.type IN (''S'', ''U'')
          AND dp2.name NOT IN (''dbo'', ''guest'')
          AND dp.state = ''G'';

        INSERT INTO #DbResults (DbName, DbScore)
        SELECT @DbNameParam,
               CASE
                   WHEN @DirectUserGrants = 0 THEN 3
                   WHEN @DirectUserGrants BETWEEN 1 AND 5 THEN 2
                   WHEN @DirectUserGrants BETWEEN 6 AND 20 THEN 1
                   ELSE 0
               END;
        ';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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