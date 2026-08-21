-- Checklist: Growth projections modeled for next 6–12 months
-- Scope: DATABASE
-- Scoring: 0: No evidence found. 1: Limited evidence (1-2 matches). 2: Strong proxy evidence (3+ matches), but full compliance requires human review. 3: Not achievable automatically.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'DECLARE @Matches TABLE (Source NVARCHAR(128), Name NVARCHAR(128));
INSERT INTO @Matches SELECT ''Object'', name FROM sys.objects WHERE name LIKE ''%growth%'' OR name LIKE ''%projection%'' OR name LIKE ''%capacity%'' OR name LIKE ''%sizing%'' OR name LIKE ''%forecast%'';
INSERT INTO @Matches SELECT ''Property'', name FROM sys.extended_properties WHERE CAST(value AS NVARCHAR(MAX)) LIKE ''%growth%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%projection%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%capacity%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%sizing%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%forecast%'';
DECLARE @Count INT = (SELECT COUNT(*) FROM @Matches);
DECLARE @Evidence NVARCHAR(MAX) = (SELECT STRING_AGG(Source + '' '' + Name, '', '') FROM @Matches);
DECLARE @DbScore INT = CASE WHEN @Count >= 3 THEN 2 WHEN @Count >= 1 THEN 1 ELSE 0 END;
DECLARE @DbFinding NVARCHAR(MAX) = CASE WHEN @Count = 0 THEN ''No evidence of growth modeling found'' ELSE ''Found '' + CAST(@Count AS NVARCHAR(10)) + '' indicators: '' + ISNULL(@Evidence, ''N/A'') END;
INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @DbFinding);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @Matches TABLE (Source NVARCHAR(128), Name NVARCHAR(128));
INSERT INTO @Matches SELECT ''Object'', name FROM sys.objects WHERE name LIKE ''%growth%'' OR name LIKE ''%projection%'' OR name LIKE ''%capacity%'' OR name LIKE ''%sizing%'' OR name LIKE ''%forecast%'';
INSERT INTO @Matches SELECT ''Property'', name FROM sys.extended_properties WHERE CAST(value AS NVARCHAR(MAX)) LIKE ''%growth%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%projection%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%capacity%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%sizing%'' OR CAST(value AS NVARCHAR(MAX)) LIKE ''%forecast%'';
DECLARE @Count INT = (SELECT COUNT(*) FROM @Matches);
DECLARE @Evidence NVARCHAR(MAX) = (SELECT STRING_AGG(Source + '' '' + Name, '', '') FROM @Matches);
DECLARE @DbScore INT = CASE WHEN @Count >= 3 THEN 2 WHEN @Count >= 1 THEN 1 ELSE 0 END;
DECLARE @DbFinding NVARCHAR(MAX) = CASE WHEN @Count = 0 THEN ''No evidence of growth modeling found'' ELSE ''Found '' + CAST(@Count AS NVARCHAR(10)) + '' indicators: '' + ISNULL(@Evidence, ''N/A'') END;
INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @DbFinding);';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;