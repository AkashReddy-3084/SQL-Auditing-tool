-- Checklist: Data quality framework formally defined with rules, ownership, and scoring
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=One component found; 2=Two+ components found; 3=Capped at 2 (Indirect evidence)
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
        DECLARE @RulesFound BIT = 0;
        DECLARE @OwnershipFound BIT = 0;
        DECLARE @ScoringFound BIT = 0;
        DECLARE @ComponentCount INT = 0;

        -- 1. Check for Rules (Check Constraints)
        IF EXISTS (SELECT 1 FROM sys.check_constraints) SET @RulesFound = 1;

        -- 2. Check for Ownership (Extended Properties with ''Owner'' or ''Steward'' in name)
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE name LIKE ''%Owner%'' OR name LIKE ''%Steward%'') SET @OwnershipFound = 1;

        -- 3. Check for Scoring (Tables with ''DQ'', ''Score'', ''Quality'' in name)
        IF EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%DQ%'' OR name LIKE ''%Score%'' OR name LIKE ''%Quality%'') SET @ScoringFound = 1;

        SET @ComponentCount = (@RulesFound + @OwnershipFound + @ScoringFound);

        -- Scoring Logic
        DECLARE @DbScore INT = 0;
        IF @ComponentCount >= 2 SET @DbScore = 2;
        ELSE IF @ComponentCount = 1 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);
        ';
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