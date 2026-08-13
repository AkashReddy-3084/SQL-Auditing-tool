-- Checklist: Foreign keys enforced where integrity matters (or documented trusted-by-ETL exceptions)
-- Scope: DATABASE
-- Scoring: 0=No FKs exist; 1=>30% disabled without documentation; 2=Minority disabled without documentation; 3=All enabled or all disabled explicitly documented as ETL exceptions.
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
        DECLARE @TotalFK INT, @EnabledFK INT, @DisabledDocFK INT, @DisabledNoDocFK INT;
        SELECT 
            @TotalFK = COUNT(fk.object_id),
            @EnabledFK = SUM(CASE WHEN fk.is_disabled = 0 THEN 1 ELSE 0 END),
            @DisabledDocFK = SUM(CASE WHEN fk.is_disabled = 1 AND EXISTS (
                SELECT 1 FROM sys.extended_properties ep 
                WHERE ep.major_id = fk.object_id AND ep.minor_id = 0 
                AND (ep.name LIKE ''%ETL%'' OR ep.name LIKE ''%Trusted%'' OR ep.name LIKE ''%Exception%'')
            ) THEN 1 ELSE 0 END),
            @DisabledNoDocFK = SUM(CASE WHEN fk.is_disabled = 1 AND NOT EXISTS (
                SELECT 1 FROM sys.extended_properties ep 
                WHERE ep.major_id = fk.object_id AND ep.minor_id = 0 
                AND (ep.name LIKE ''%ETL%'' OR ep.name LIKE ''%Trusted%'' OR ep.name LIKE ''%Exception%'')
            ) THEN 1 ELSE 0 END)
        FROM sys.foreign_keys fk;
        
        DECLARE @DbScore INT = 0;
        IF @TotalFK = 0 SET @DbScore = 0;
        ELSE IF @DisabledNoDocFK > 0 AND (@DisabledNoDocFK * 100.0 / @TotalFK) > 30 SET @DbScore = 1;
        ELSE IF @DisabledNoDocFK > 0 SET @DbScore = 2;
        ELSE SET @DbScore = 3;
        
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
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