-- Checklist: Naming conventions consistent for tables, columns, and schemas
-- Scope: DATABASE
-- Scoring: 0=<50% consistent or <5 objects, 1=50-74%, 2=75-89%, 3=>=90% consistent naming pattern
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);
CREATE TABLE #NamingStats (DbName NVARCHAR(256), Total INT, Consistent INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        WITH AllNames AS (
            SELECT name FROM sys.tables WHERE type_desc = ''USER_TABLE''
            UNION ALL
            SELECT name FROM sys.columns
            UNION ALL
            SELECT name FROM sys.schemas
        ),
        Patterns AS (
            SELECT
                COUNT(*) AS Total,
                SUM(CASE WHEN name = LOWER(name) THEN 1 ELSE 0 END) AS LowerCount,
                SUM(CASE WHEN name = UPPER(name) THEN 1 ELSE 0 END) AS UpperCount,
                SUM(CASE WHEN name LIKE ''[A-Z][a-z]%%'' THEN 1 ELSE 0 END) AS PascalCount,
                SUM(CASE WHEN name LIKE ''[a-z]_[a-z]%%'' THEN 1 ELSE 0 END) AS SnakeCount
            FROM AllNames
        )
        SELECT ''' + @DbName + ''' AS DbName,
               Total,
               (SELECT MAX(Cnt) FROM (VALUES (LowerCount), (UpperCount), (PascalCount), (SnakeCount)) AS V(Cnt)) AS Consistent
        FROM Patterns;';
        INSERT INTO #NamingStats EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #NamingStats VALUES (@DbName, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

INSERT INTO #DbResults
SELECT DbName,
       CASE
           WHEN Total < 5 THEN 0
           WHEN CAST(Consistent AS FLOAT) / Total >= 0.90 THEN 3
           WHEN CAST(Consistent AS FLOAT) / Total >= 0.75 THEN 2
           WHEN CAST(Consistent AS FLOAT) / Total >= 0.50 THEN 1
           ELSE 0
       END AS DbScore
FROM #NamingStats;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
DROP TABLE #NamingStats;
SELECT @Result AS Result, @Score AS Score;