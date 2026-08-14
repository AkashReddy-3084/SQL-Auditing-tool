-- Checklist: DQ failures halt progression where critical (bad data not silently promoted)
-- Scope: DATABASE
-- Scoring: 0=No DQ/ETL procs or no halt logic; 1=DQ procs exist but <50% halt on failure; 2=>=50% halt on failure; 3=100% halt on failure
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
        DECLARE @TotalDQ INT = 0;
        DECLARE @HaltCount INT = 0;

        SELECT @TotalDQ = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND m.definition IS NOT NULL
          AND (p.name LIKE ''%DQ%'' OR p.name LIKE ''%Validate%'' OR p.name LIKE ''%Check%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%ETL%'' OR p.name LIKE ''%Staging%'');

        SELECT @HaltCount = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND m.definition IS NOT NULL
          AND (p.name LIKE ''%DQ%'' OR p.name LIKE ''%Validate%'' OR p.name LIKE ''%Check%'' OR p.name LIKE ''%Load%'' OR p.name LIKE ''%ETL%'' OR p.name LIKE ''%Staging%'')
          AND (m.definition LIKE ''%THROW%'' OR m.definition LIKE ''%RAISERROR%'' OR m.definition LIKE ''%GOTO%'' OR m.definition LIKE ''%RETURN -%'' OR m.definition LIKE ''%Quarantine%'' OR m.definition LIKE ''%ErrorTable%'');

        DECLARE @DbScore INT = 0;
        IF @TotalDQ = 0 SET @DbScore = 0;
        ELSE IF @HaltCount = 0 SET @DbScore = 0;
        ELSE IF CAST(@HaltCount AS FLOAT) / @TotalDQ < 0.5 SET @DbScore = 1;
        ELSE IF CAST(@HaltCount AS FLOAT) / @TotalDQ < 1.0 SET @DbScore = 2;
        ELSE SET @DbScore = 3;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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