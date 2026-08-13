-- Checklist: Consent / purpose tracking integrated where applicable
-- Scope: DATABASE
-- Scoring: 0=No evidence found; 1=1-2 relevant columns/tables found; 2=3+ relevant columns/tables found; 3=Comprehensive tracking across all major tables (capped at 2 for proxy evidence per guidelines)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @MatchCount INT = 0;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @MatchCount = 0; -- Reset for each database to prevent stale values
    
    BEGIN TRY
        SET @Sql = N'SELECT @MatchCount = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id
            WHERE c.name LIKE ''%consent%'' OR c.name LIKE ''%purpose%'' OR c.name LIKE ''%tracking%''
               OR c.name LIKE ''%privacy%'' OR c.name LIKE ''%gdpr%'' OR c.name LIKE ''%ccpa%''
               OR t.name LIKE ''%consent%'' OR t.name LIKE ''%purpose%'' OR t.name LIKE ''%tracking%'';';
        
        EXEC sp_executesql @Sql, N'@MatchCount INT OUTPUT', @MatchCount OUTPUT;
        
        IF @MatchCount >= 3
            INSERT INTO #DbResults VALUES (@DbName, 2);
        ELSE IF @MatchCount >= 1
            INSERT INTO #DbResults VALUES (@DbName, 1);
        ELSE
            INSERT INTO #DbResults VALUES (@DbName, 0);
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