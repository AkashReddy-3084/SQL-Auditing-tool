-- Checklist: Numeric / Financial: precision preserved; no rounding errors; currency codes valid
-- Scope: DATABASE
-- Scoring: 0 = Fail (FLOAT/REAL used for financial data), 1 = Partial Pass (mixed precision or invalid currency codes), 2 = Mostly Pass (all use DECIMAL/NUMERIC or MONEY, but currency codes are non-standard), 3 = Pass (all use DECIMAL/NUMERIC with scale>=2 and currency codes are CHAR(3)/VARCHAR(3)).
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
DECLARE @Total INT, @Good INT, @Bad INT, @Money INT, @CurrTotal INT, @CurrValid INT;
SELECT @Total = COUNT(*),
       @Good = SUM(CASE WHEN t.name IN (''decimal'', ''numeric'') AND c.scale >= 2 THEN 1 ELSE 0 END),
       @Bad = SUM(CASE WHEN t.name IN (''float'', ''real'') THEN 1 ELSE 0 END),
       @Money = SUM(CASE WHEN t.name IN (''money'', ''smallmoney'') THEN 1 ELSE 0 END),
       @CurrTotal = SUM(CASE WHEN c.name LIKE ''%curr%'' OR c.name LIKE ''%currency%'' OR c.name LIKE ''%iso%'' THEN 1 ELSE 0 END),
       @CurrValid = SUM(CASE WHEN (c.name LIKE ''%curr%'' OR c.name LIKE ''%currency%'' OR c.name LIKE ''%iso%'') AND t.name IN (''char'', ''varchar'') AND c.max_length IN (3, 6) THEN 1 ELSE 0 END)
FROM sys.columns c
JOIN sys.types t ON c.user_type_id = t.user_type_id
JOIN sys.tables tab ON c.object_id = tab.object_id
WHERE t.name IN (''decimal'', ''numeric'', ''money'', ''smallmoney'', ''float'', ''real'')
   OR c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%cost%'' OR c.name LIKE ''%balance%'' OR c.name LIKE ''%revenue%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%fee%'' OR c.name LIKE ''%currency%'' OR c.name LIKE ''%curr%'' OR c.name LIKE ''%iso%'';

DECLARE @DbScore INT = 3;
IF @Total > 0 BEGIN
    IF @Bad > 0 SET @DbScore = 0;
    ELSE IF @Good = @Total SET @DbScore = 3;
    ELSE IF @Good + @Money = @Total SET @DbScore = 2;
    ELSE SET @DbScore = 1;

    IF @CurrTotal > 0 AND @CurrValid < @CurrTotal SET @DbScore = @DbScore - 1;
    IF @DbScore < 0 SET @DbScore = 0;
END
INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore);';
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