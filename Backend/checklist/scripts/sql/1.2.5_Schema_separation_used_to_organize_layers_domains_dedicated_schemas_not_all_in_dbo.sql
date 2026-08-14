-- Checklist: Schema separation used to organize layers/domains (dedicated schemas, not all in dbo)
-- Scope: DATABASE
-- Scoring: 0=All tables in dbo; 1=Majority in dbo; 2=Minority in dbo; 3=Zero tables in dbo

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Create temp table to collect per-database results
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
        SELECT 
            CASE 
                WHEN COUNT(*) = 0 THEN 0
                WHEN SUM(CASE WHEN s.name = ''dbo'' THEN 1 ELSE 0 END) = COUNT(*) THEN 0
                WHEN SUM(CASE WHEN s.name = ''dbo'' THEN 1 ELSE 0 END) > (COUNT(*) * 1.0 / 2.0) THEN 1
                WHEN SUM(CASE WHEN s.name = ''dbo'' THEN 1 ELSE 0 END) > 0 THEN 2
                ELSE 3
            END AS DbScore
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id;';
        
        INSERT INTO #DbResults (DbName, DbScore)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    
    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;