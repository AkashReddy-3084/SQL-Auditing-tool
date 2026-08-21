-- Checklist: Schema separation used to organize layers/domains (dedicated schemas, not all in dbo)
-- Scope: DATABASE
-- Scoring: 3 = 0% in dbo; 2 = 1-20% in dbo; 1 = 21-50% in dbo; 0 = >50% in dbo or only dbo exists

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
            WHEN TotalObjs = 0 THEN 0
            WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) = 0 THEN 3
            WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) <= 0.2 THEN 2
            WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) <= 0.5 THEN 1
            ELSE 0 
        END,
        'Total objects: ' + CAST(TotalObjs AS VARCHAR(10)) + ', dbo objects: ' + CAST(DboObjs AS VARCHAR(10)) + ' (' + ISNULL(CAST(CAST(CAST(DboObjs AS FLOAT)/NULLIF(TotalObjs,0)*100 AS DECIMAL(5,2)) AS VARCHAR(10)), '0') + '%)'
    FROM (
        SELECT 
            COUNT(*) AS TotalObjs,
            SUM(CASE WHEN s.name = 'dbo' THEN 1 ELSE 0 END) AS DboObjs
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
    ) AS Stats;
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
            SET @Sql = N'SELECT @p_Db,
                CASE 
                    WHEN TotalObjs = 0 THEN 0
                    WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) = 0 THEN 3
                    WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) <= 0.2 THEN 2
                    WHEN CAST(DboObjs AS FLOAT) / NULLIF(TotalObjs, 0) <= 0.5 THEN 1
                    ELSE 0 
                END,
                ''Total objects: '' + CAST(TotalObjs AS VARCHAR(10)) + '', dbo objects: '' + CAST(DboObjs AS VARCHAR(10)) + '' ('' + ISNULL(CAST(CAST(CAST(DboObjs AS FLOAT)/NULLIF(TotalObjs,0)*100 AS DECIMAL(5,2)) AS VARCHAR(10)), ''0'') + ''%)''
                FROM (
                    SELECT 
                        COUNT(*) AS TotalObjs,
                        SUM(CASE WHEN s.name = ''dbo'' THEN 1 ELSE 0 END) AS DboObjs
                    FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
                    JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id
                ) AS Stats;';

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

-- Use dynamic SQL for aggregation to support older SQL Server versions (C4)
DECLARE @AggSql NVARCHAR(MAX) = N'
    SELECT 
        @p_DbQueried = (SELECT STRING_AGG(DbName, '', '') FROM #DbResults),
        @p_Score = (SELECT MIN(DbScore) FROM #DbResults),
        @p_Finding = (SELECT STRING_AGG(DbName + '': '' + Finding, ''; '') FROM #DbResults)
';

-- Check for SQL Server 2017+ (STRING_AGG support)
IF (SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT)) >= 14
BEGIN
    EXEC sp_executesql @AggSql, N'@p_DbQueried NVARCHAR(MAX) OUTPUT, @p_Score INT OUTPUT, @p_Finding NVARCHAR(MAX) OUTPUT', 
        @p_DbQueried = @DatabaseQueried OUTPUT, @p_Score = @Score OUTPUT, @p_Finding = @Finding OUTPUT;
END
ELSE
BEGIN
    -- Fallback for older versions using XML PATH
    SELECT @DatabaseQueried = STUFF((SELECT ', ' + DbName FROM #DbResults FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');
    SELECT @Score = MIN(DbScore) FROM #DbResults;
    SELECT @Finding = STUFF((SELECT '; ' + DbName + ': ' + Finding FROM #DbResults FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');
END

SET @DatabaseQueried = ISNULL(@DatabaseQueried, 'None');
SET @Score = ISNULL(@Score, 0);
SET @Finding = ISNULL(@Finding, 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;