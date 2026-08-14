-- Checklist: Constraints are TRUSTED (not disabled/untrusted, which hurts the optimizer)
-- Scope: DATABASE
-- Scoring: 0 = >10 untrusted/disabled constraints; 1 = 1-10 untrusted/disabled constraints; 2 = 0 untrusted/disabled but <5 total constraints; 3 = 0 untrusted/disabled and >=5 total constraints.
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
        DECLARE @UntrustedCount INT = 0;
        DECLARE @TotalCount INT = 0;
        
        SELECT @UntrustedCount = ISNULL(SUM(CASE WHEN is_not_trusted = 1 OR is_disabled = 1 THEN 1 ELSE 0 END), 0),
               @TotalCount = COUNT(*)
        FROM (
            SELECT is_not_trusted, is_disabled FROM sys.check_constraints
            UNION ALL
            SELECT is_not_trusted, is_disabled FROM sys.foreign_keys
        ) AS c;
        
        INSERT INTO #DbResults VALUES (@DbName, 
            CASE 
                WHEN @UntrustedCount > 10 THEN 0
                WHEN @UntrustedCount BETWEEN 1 AND 10 THEN 1
                WHEN @UntrustedCount = 0 AND @TotalCount < 5 THEN 2
                ELSE 3
            END);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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