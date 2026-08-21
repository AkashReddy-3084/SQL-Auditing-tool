-- Checklist: Source metadata captured (load timestamp, source, batch ID)
-- Scope: DATABASE
-- Scoring: 3 = all tables have all 3 metadata types; 2 = >80% tables have all 3; 1 = >50% tables have all 3; 0 = <=50% or no tables found.

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
          WHEN COUNT(*) = 0 THEN 0 
          WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) = 1 THEN 3
          WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
          WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.5 THEN 1
          ELSE 0 
        END,
        'Tables with all 3 metadata columns: ' + CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS VARCHAR(10)) + ' of ' + CAST(COUNT(*) AS VARCHAR(10))
    FROM (
        SELECT 
            t.name,
            MAX(CASE WHEN c.name LIKE '%load_date%' OR c.name LIKE '%load_time%' OR c.name LIKE '%created_at%' THEN 1 ELSE 0 END) as HasTS,
            MAX(CASE WHEN c.name LIKE '%source%' OR c.name LIKE '%src%' THEN 1 ELSE 0 END) as HasSrc,
            MAX(CASE WHEN c.name LIKE '%batch%' OR c.name LIKE '%run_id%' THEN 1 ELSE 0 END) as HasBId
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        GROUP BY t.name
    ) AS TableMeta;
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
            SET @Sql = N'SELECT 
                @p_Db,
                CASE 
                  WHEN COUNT(*) = 0 THEN 0 
                  WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) = 1 THEN 3
                  WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
                  WHEN CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.5 THEN 1
                  ELSE 0 
                END,
                ''Tables with all 3 metadata columns: '' + CAST(SUM(CASE WHEN HasTS=1 AND HasSrc=1 AND HasBId=1 THEN 1 ELSE 0 END) AS VARCHAR(10)) + '' of '' + CAST(COUNT(*) AS VARCHAR(10))
                FROM (
                    SELECT 
                        t.name,
                        MAX(CASE WHEN c.name LIKE ''%load_date%'' OR c.name LIKE ''%load_time%'' OR c.name LIKE ''%created_at%'' THEN 1 ELSE 0 END) as HasTS,
                        MAX(CASE WHEN c.name LIKE ''%source%'' OR c.name LIKE ''%src%'' THEN 1 ELSE 0 END) as HasSrc,
                        MAX(CASE WHEN c.name LIKE ''%batch%'' OR c.name LIKE ''%run_id%'' THEN 1 ELSE 0 END) as HasBId
                    FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON t.object_id = c.object_id
                    GROUP BY t.name
                ) AS TableMeta;';

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