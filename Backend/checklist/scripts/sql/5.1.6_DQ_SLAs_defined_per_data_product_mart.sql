-- Checklist: DQ SLAs defined per data product / mart
-- Scope: DATABASE
-- Scoring: 3: >=5 DQ/SLA extended properties found per DB; 2: 2-4 found; 1: 1 found; 0: None found. Proxy evidence used; full compliance requires human review.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #TargetDBs (DbName NVARCHAR(128));
CREATE TABLE #DbResults (DbName NVARCHAR(128), DbScore INT, Finding NVARCHAR(MAX));

IF @IsAzureSQLDB = 1
    INSERT INTO #TargetDBs VALUES (DB_NAME());
ELSE
    INSERT INTO #TargetDBs 
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DbName FROM #TargetDBs;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @Count INT;
        SELECT @Count = COUNT(*) 
        FROM sys.extended_properties 
        WHERE class_desc IN (''DATABASE'', ''OBJECT_OR_COLUMN'')
          AND (name LIKE ''%SLA%'' 
             OR name LIKE ''%DQ%'' 
             OR name LIKE ''%DataQuality%'' 
             OR name LIKE ''%ServiceLevel%'');
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        SELECT ''' + @DbName + ''' AS DbName,
               CASE WHEN @Count >= 5 THEN 3 WHEN @Count >= 2 THEN 2 WHEN @Count >= 1 THEN 1 ELSE 0 END AS DbScore,
               CASE WHEN @Count > 0 THEN CAST(@Count AS NVARCHAR) + '' DQ/SLA extended properties found'' ELSE ''No DQ/SLA metadata found'' END AS Finding;
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF NOT EXISTS (SELECT 1 FROM #DbResults)
BEGIN
    SET @DatabaseQueried = 'No user databases found';
    SET @Score = 0;
    SET @Finding = 'No user databases available for evaluation';
END
ELSE
BEGIN
    SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
    SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
    SET @Finding = ISNULL(
        (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
        'No non-compliant findings found'
    );
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #TargetDBs;
DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;