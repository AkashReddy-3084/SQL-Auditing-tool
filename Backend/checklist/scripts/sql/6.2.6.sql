SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#ClassificationFindings') IS NOT NULL DROP TABLE #ClassificationFindings;
CREATE TABLE #ClassificationFindings (
    DatabaseName sysname NOT NULL,
    ClassifiedColumnCount int NOT NULL,
    StatusNote nvarchar(200) NOT NULL
);

DECLARE @db sysname;
DECLARE @sql nvarchar(max);
DECLARE @engineMajor int = CAST(SERVERPROPERTY('ProductMajorVersion') AS int);
DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding nvarchar(max);
DECLARE @dbCount int;
DECLARE @classifiedDbCount int;
DECLARE @totalClassifiedCols int;
DECLARE @errorDbCount int;
DECLARE @dbList nvarchar(max);

IF @engineMajor IS NOT NULL AND @engineMajor < 13
BEGIN
    SET @Score = 1;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'SQL Server version does not expose sys.sensitivity_classifications; Data Discovery & Classification catalog unavailable for automated verification.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = N'ONLINE'
  AND HAS_DBACCESS(name) = 1
  AND is_read_only = 0
  AND is_distributor = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
USE ' + QUOTENAME(@db) + N';
IF OBJECT_ID(''sys.sensitivity_classifications'', ''V'') IS NULL
BEGIN
    INSERT INTO #ClassificationFindings (DatabaseName, ClassifiedColumnCount, StatusNote)
    VALUES (DB_NAME(), -1, N''sys.sensitivity_classifications not available in this database context'');
END
ELSE
BEGIN
    INSERT INTO #ClassificationFindings (DatabaseName, ClassifiedColumnCount, StatusNote)
    SELECT
        DB_NAME(),
        COUNT(*),
        CASE WHEN COUNT(*) > 0
             THEN N''Sensitivity classifications present''
             ELSE N''No sensitivity classifications found''
        END
    FROM sys.sensitivity_classifications sc
    INNER JOIN sys.columns c
        ON sc.major_id = c.object_id
       AND sc.minor_id = c.column_id
    INNER JOIN sys.tables t
        ON c.object_id = t.object_id
    WHERE t.is_ms_shipped = 0;
END';

        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #ClassificationFindings (DatabaseName, ClassifiedColumnCount, StatusNote)
        VALUES (@db, -1, LEFT(N'Error: ' + ERROR_MESSAGE(), 200));
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @dbCount = (SELECT COUNT(*) FROM #ClassificationFindings);
SET @classifiedDbCount = (SELECT COUNT(*) FROM #ClassificationFindings WHERE ClassifiedColumnCount > 0);
SET @totalClassifiedCols = (SELECT ISNULL(SUM(CASE WHEN ClassifiedColumnCount > 0 THEN ClassifiedColumnCount ELSE 0 END), 0) FROM #ClassificationFindings);
SET @errorDbCount = (SELECT COUNT(*) FROM #ClassificationFindings WHERE ClassifiedColumnCount < 0);

IF @dbCount = 0
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    DROP TABLE #ClassificationFindings;
    RETURN;
END

SET @DatabaseQueried = N'ALL';

IF @errorDbCount = @dbCount
BEGIN
    SET @Score = 1;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'Unable to query sensitivity classifications in any user database (catalog unavailable or access errors). Manual verification of Data Discovery & Classification required.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    DROP TABLE #ClassificationFindings;
    RETURN;
END

;WITH db_names AS (
    SELECT DatabaseName
    FROM #ClassificationFindings
    WHERE ClassifiedColumnCount > 0
)
SELECT @dbList = STUFF((
    SELECT N', ' + DatabaseName
    FROM db_names
    ORDER BY DatabaseName
    FOR XML PATH(''), TYPE
).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @classifiedDbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No sensitivity classifications found across ' + CAST(@dbCount AS nvarchar(20))
        + N' accessible user database(s). Sensitive data does not appear to be labeled via SQL Data Discovery & Classification.';
END
ELSE IF @classifiedDbCount = @dbCount
    OR (@dbCount = 1 AND @classifiedDbCount = 1)
    OR (@classifiedDbCount * 1.0 / NULLIF(@dbCount, 0) >= 0.5)
BEGIN
    SET @Score = 3;
    SET @Finding = N'Sensitivity classifications present in ' + CAST(@classifiedDbCount AS nvarchar(20))
        + N' of ' + CAST(@dbCount AS nvarchar(20)) + N' user database(s); total classified columns: '
        + CAST(@totalClassifiedCols AS nvarchar(20)) + N'. Databases: ' + ISNULL(@dbList, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Sensitivity classifications found in only ' + CAST(@classifiedDbCount AS nvarchar(20))
        + N' of ' + CAST(@dbCount AS nvarchar(20)) + N' user database(s); total classified columns: '
        + CAST(@totalClassifiedCols AS nvarchar(20)) + N'. Databases with labels: ' + ISNULL(@dbList, N'n/a')
        + N'. Classification coverage is incomplete.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

DROP TABLE #ClassificationFindings;