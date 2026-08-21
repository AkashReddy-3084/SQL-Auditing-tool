-- Checklist: Consistent formatting and naming conventions across objects
-- Scope: DATABASE
-- Scoring: proxy check, max achievable 2, aggregated worst-case across databases.
--   per-db 2 = no naming anti-patterns; 1 = <=5 anti-patterns; 0 = >5 or evaluation failed

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT NULL, BadCount INT NULL, Finding NVARCHAR(MAX) NULL);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate only the current connected database.
    ;WITH Bad AS (
        SELECT name FROM sys.objects
        WHERE type IN ('U','V','P','FN','IF','TF','TR')
          AND (name LIKE '% %' OR name LIKE ' %' OR name LIKE '% ' OR name LIKE '%[^a-zA-Z0-9_]%')
    )
    INSERT INTO #DbResults (DbName, DbScore, BadCount, Finding)
    SELECT DB_NAME(), NULL,
        (SELECT COUNT(*) FROM Bad),
        ISNULL(STUFF((SELECT ', ' + name FROM Bad ORDER BY name FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
               'No non-compliant object names found');
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            ;WITH Bad AS (
                SELECT name FROM sys.objects
                WHERE type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'',''TR'')
                  AND (name LIKE ''% %'' OR name LIKE '' %'' OR name LIKE ''% '' OR name LIKE ''%[^a-zA-Z0-9_]%'')
            )
            INSERT INTO #DbResults (DbName, DbScore, BadCount, Finding)
            SELECT @dbn, NULL,
                (SELECT COUNT(*) FROM Bad),
                ISNULL(STUFF((SELECT '', '' + name FROM Bad ORDER BY name FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, ''''),
                       ''No non-compliant object names found'');';
        BEGIN TRY
            EXEC sp_executesql @Sql, N'@dbn SYSNAME', @dbn = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, BadCount, Finding)
            VALUES (@DbName, 0, NULL, 'Evaluation failed/unavailable: ' + ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

UPDATE #DbResults
SET DbScore = CASE
        WHEN BadCount IS NULL THEN 0
        WHEN BadCount = 0     THEN 2
        WHEN BadCount <= 5    THEN 1
        ELSE 0
    END
WHERE DbScore IS NULL;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @DatabaseQueried = ISNULL(STUFF((SELECT ', ' + DbName FROM #DbResults ORDER BY DbName
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'none');

SET @Finding = ISNULL(STUFF((SELECT '; ' + DbName + ': ' + Finding FROM #DbResults ORDER BY DbName
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), 'No user databases evaluated')
    + '. NOTE: This script provides automated evidence (object-name anti-patterns). Full compliance requires human review of broader formatting/naming standards.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #DbResults;