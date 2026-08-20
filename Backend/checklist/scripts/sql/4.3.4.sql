-- Checklist: No redundant/duplicate/overlapping indexes
-- Scope: DATABASE
-- Scoring: 3 = no redundant indexes; 2 = < 5% of indexes redundant; 1 = 5-25% redundant; 0 = > 25% redundant

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN RedundantCount = 0 THEN 3 
            WHEN CAST(RedundantCount * 100.0 / NULLIF(TotalIndexes, 0) AS FLOAT) < 5 THEN 2 
            WHEN CAST(RedundantCount * 100.0 / NULLIF(TotalIndexes, 0) AS FLOAT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN RedundantCount = 0 THEN 'No redundant indexes found'
            ELSE 'Redundant indexes: ' + RedundantList 
        END
    FROM (
        SELECT 
            COUNT(DISTINCT i.index_id) as RedundantCount,
            (SELECT COUNT(*) FROM sys.indexes WHERE type > 0) as TotalIndexes,
            STRING_AGG(CAST(i.name AS NVARCHAR(MAX)), ', ') as RedundantList
        FROM sys.indexes i
        JOIN sys.index_columns ic1 ON i.object_id = ic1.object_id AND i.index_id = ic1.index_id
        JOIN sys.indexes i2 ON i.object_id = i2.object_id AND i.index_id <> i2.index_id
        JOIN sys.index_columns ic2 ON i2.object_id = ic2.object_id AND i2.index_id = ic2.index_id
        WHERE ic1.column_id = 1 AND ic2.column_id = 1 AND ic1.column_id = ic2.column_id
        AND i.name <> i2.name
        AND i.type = i2.type
    ) AS RedundancyCheck;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
            SELECT 
                @p_Db,
                CASE 
                    WHEN RedundantCount = 0 THEN 3 
                    WHEN CAST(RedundantCount * 100.0 / NULLIF(TotalIndexes, 0) AS FLOAT) < 5 THEN 2 
                    WHEN CAST(RedundantCount * 100.0 / NULLIF(TotalIndexes, 0) AS FLOAT) < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN RedundantCount = 0 THEN ''No redundant indexes found''
                    ELSE ''Redundant indexes: '' + RedundantList 
                END
            FROM (
                SELECT 
                    COUNT(DISTINCT i.index_id) as RedundantCount,
                    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.indexes WHERE type > 0) as TotalIndexes,
                    STRING_AGG(CAST(i.name AS NVARCHAR(MAX)), '', '') as RedundantList
                FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i
                JOIN ' + QUOTENAME(@DbName) + N'.sys.index_columns ic1 ON i.object_id = ic1.object_id AND i.index_id = ic1.index_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i2 ON i.object_id = i2.object_id AND i.index_id <> i2.index_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.index_columns ic2 ON i2.object_id = ic2.object_id AND i2.index_id = ic2.index_id
                WHERE ic1.column_id = 1 AND ic2.column_id = 1 AND ic1.column_id = ic2.column_id
                AND i.name <> i2.name
                AND i.type = i2.type
            ) AS RedundancyCheck;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;