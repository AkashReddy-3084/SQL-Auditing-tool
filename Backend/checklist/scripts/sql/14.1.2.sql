-- Checklist: SARGable predicates used (no functions wrapping indexed columns)
-- Scope: DATABASE
-- Scoring: 3 = no non-SARGable patterns; 2 = < 5% of modules; 1 = < 25% of modules; 0 = >= 25% of modules

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
            WHEN TotalModules = 0 THEN 3 
            WHEN CAST(BadModules * 100.0 / NULLIF(TotalModules, 0) AS INT) < 5 THEN 2 
            WHEN CAST(BadModules * 100.0 / NULLIF(TotalModules, 0) AS INT) < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN BadModules = 0 THEN 'No non-SARGable patterns found' 
            ELSE 'Non-SARGable patterns found in ' + CAST(BadModules AS VARCHAR(10)) + ' of ' + CAST(TotalModules AS VARCHAR(10)) + ' modules' 
        END
    FROM (
        SELECT 
            COUNT(*) AS TotalModules,
            SUM(CASE WHEN m.definition LIKE '%WHERE%LEFT(%' 
                OR m.definition LIKE '%WHERE%SUBSTRING(%' 
                OR m.definition LIKE '%WHERE%YEAR(%' 
                OR m.definition LIKE '%WHERE%MONTH(%' 
                OR m.definition LIKE '%WHERE%DAY(%' 
                OR m.definition LIKE '%JOIN%ON%LEFT(%' 
                OR m.definition LIKE '%JOIN%ON%SUBSTRING(%' 
                OR m.definition LIKE '%JOIN%ON%YEAR(%' 
                OR m.definition LIKE '%JOIN%ON%MONTH(%' 
                OR m.definition LIKE '%JOIN%ON%DAY(%' THEN 1 ELSE 0 END) AS BadModules
        FROM sys.sql_modules m
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
            SET @Sql = N'
            DECLARE @TotalModules INT;
            DECLARE @BadModules INT;
            
            SELECT @TotalModules = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules;
            
            SELECT @BadModules = SUM(CASE WHEN m.definition LIKE ''%WHERE%LEFT(%'' 
                OR m.definition LIKE ''%WHERE%SUBSTRING(%'' 
                OR m.definition LIKE ''%WHERE%YEAR(%'' 
                OR m.definition LIKE ''%WHERE%MONTH(%'' 
                OR m.definition LIKE ''%WHERE%DAY(%'' 
                OR m.definition LIKE ''%JOIN%ON%LEFT(%'' 
                OR m.definition LIKE ''%JOIN%ON%SUBSTRING(%'' 
                OR m.definition LIKE ''%JOIN%ON%YEAR(%'' 
                OR m.definition LIKE ''%JOIN%ON%MONTH(%'' 
                OR m.definition LIKE ''%JOIN%ON%DAY(%'' THEN 1 ELSE 0 END)
            FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m;

            SELECT @p_Db,
                   CASE 
                     WHEN @TotalModules = 0 THEN 3
                     WHEN @BadModules = 0 THEN 3 
                     WHEN CAST(@BadModules * 100.0 / NULLIF(@TotalModules, 0) AS INT) < 5 THEN 2 
                     WHEN CAST(@BadModules * 100.0 / NULLIF(@TotalModules, 0) AS INT) < 25 THEN 1 
                     ELSE 0 
                   END,
                   CASE 
                     WHEN @BadModules = 0 THEN ''No non-SARGable patterns found'' 
                     ELSE ''Non-SARGable patterns found in '' + CAST(@BadModules AS VARCHAR(10)) + '' of '' + CAST(@TotalModules AS VARCHAR(10)) + '' modules'' 
                   END;';

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