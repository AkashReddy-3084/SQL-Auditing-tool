-- Checklist: Ownership documented — not tribal knowledge
-- Scope: DATABASE
-- Scoring: 0=No ownership metadata found, 1=<25% documented, 2=25-75% documented or consistent dbo ownership, 3=>75% documented via extended properties
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
        DECLARE @Total INT = (SELECT COUNT(*) FROM sys.schemas WHERE principal_id > 4) + (SELECT COUNT(*) FROM sys.tables);
        DECLARE @Doc INT = (SELECT COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE major_id > 0 AND (name IN (''Owner'',''Contact'',''Team'',''Steward'') OR value LIKE ''%owner%'' OR value LIKE ''%contact%'' OR value LIKE ''%team%''));
        DECLARE @DboSchemas INT = (SELECT COUNT(*) FROM sys.schemas WHERE principal_id = 1);
        DECLARE @Pct FLOAT = CASE WHEN @Total = 0 THEN 100 ELSE (@Doc * 100.0 / @Total) END;
        DECLARE @DbScore INT = CASE
            WHEN @Pct >= 75 THEN 3
            WHEN @Pct >= 25 THEN 2
            WHEN @Pct > 0 THEN 1
            WHEN @DboSchemas > 0 AND @Total > 0 THEN 2
            ELSE 0
        END;
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore);';
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