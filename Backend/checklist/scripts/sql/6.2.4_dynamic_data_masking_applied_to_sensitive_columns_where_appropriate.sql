-- Checklist: Dynamic Data Masking applied to sensitive columns where appropriate
-- Scope: DATABASE
-- Scoring: 0=No masked columns found; 1=Masked columns exist but none match sensitive patterns; 2=Some sensitive columns are masked; 3=All sensitive-pattern columns are masked
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
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
        DECLARE @TotalMasked INT = 0;
        DECLARE @SensitiveMasked INT = 0;
        DECLARE @TotalSensitive INT = 0;

        SELECT @TotalMasked = COUNT(*) FROM sys.masked_columns;

        SELECT @SensitiveMasked = COUNT(*) FROM sys.masked_columns
        WHERE name LIKE ''%ssn%'' OR name LIKE ''%credit%'' OR name LIKE ''%email%'' OR name LIKE ''%phone%'' OR name LIKE ''%password%'' OR name LIKE ''%secret%'' OR name LIKE ''%card%'';

        SELECT @TotalSensitive = COUNT(*) FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%credit%'' OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%password%'' OR c.name LIKE ''%secret%'' OR c.name LIKE ''%card%'';

        DECLARE @DbScore INT = 0;
        IF @TotalMasked = 0 SET @DbScore = 0;
        ELSE IF @SensitiveMasked = 0 SET @DbScore = 1;
        ELSE IF @SensitiveMasked < @TotalSensitive SET @DbScore = 2;
        ELSE SET @DbScore = 3;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;