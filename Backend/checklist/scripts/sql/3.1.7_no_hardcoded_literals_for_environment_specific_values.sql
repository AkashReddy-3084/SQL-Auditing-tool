-- Checklist: No hardcoded literals for environment-specific values
-- Scope: DATABASE
-- Scoring: 3=Pass (0 matches), 2=Mostly Pass (1-2 matches), 1=Partial Pass (3-5 matches), 0=Fail (>5 matches)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), MatchCount INT, DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #DbResults (DbName, MatchCount)
        SELECT ''' + @DbName + ''', COUNT(*)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE m.definition LIKE ''%\\%\\%''
           OR m.definition LIKE ''%C:\%''
           OR m.definition LIKE ''%D:\%''
           OR m.definition LIKE ''%http://%''
           OR m.definition LIKE ''%https://%''
           OR m.definition LIKE ''%''''PROD''''%''
           OR m.definition LIKE ''%''''DEV''''%''
           OR m.definition LIKE ''%''''TEST''''%''
           OR m.definition LIKE ''%''''QA''''%''
           OR m.definition LIKE ''%''''UAT''''%''
           OR m.definition LIKE ''%''''STG''''%'';';
        EXEC sp_executesql @Sql;
        
        UPDATE #DbResults
        SET DbScore = CASE 
            WHEN MatchCount = 0 THEN 3
            WHEN MatchCount BETWEEN 1 AND 2 THEN 2
            WHEN MatchCount BETWEEN 3 AND 5 THEN 1
            ELSE 0
        END
        WHERE DbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;