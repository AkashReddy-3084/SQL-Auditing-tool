-- Checklist: TRY...CATCH with proper error raising/logging (THROW/RAISERROR)
-- Scope: DATABASE
-- Scoring: 0=No TRY...CATCH found, 1=<20% coverage or missing THROW/RAISERROR, 2=20-79% coverage with proper handling, 3=>=80% coverage with proper handling
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
        DECLARE @TotalModules INT;
        DECLARE @WithProperHandling INT;
        DECLARE @DbScore INT = 0;

        SELECT @TotalModules = COUNT(*)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''TF'', ''IF'', ''TR'')
        AND m.definition IS NOT NULL;

        SELECT @WithProperHandling = COUNT(*)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''TF'', ''IF'', ''TR'')
        AND m.definition IS NOT NULL
        AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%''
        AND (m.definition LIKE ''%THROW%'' OR m.definition LIKE ''%RAISERROR%'');

        IF @TotalModules = 0 SET @DbScore = 3;
        ELSE IF @WithProperHandling = 0 SET @DbScore = 0;
        ELSE BEGIN
            DECLARE @Pct FLOAT = CAST(@WithProperHandling AS FLOAT) / CAST(@TotalModules AS FLOAT) * 100.0;
            IF @Pct < 20.0 SET @DbScore = 1;
            ELSE IF @Pct < 80.0 SET @DbScore = 2;
            ELSE SET @DbScore = 3;
        END;

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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;