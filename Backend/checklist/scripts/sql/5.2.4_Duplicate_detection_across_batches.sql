-- Checklist: Duplicate detection across batches
-- Scope: DATABASE
-- Scoring: 0=No staging/ETL found; 1=Staging exists but no unique constraints or duplicate logic; 2=Partial evidence (unique constraints OR duplicate logic found); 3=Robust evidence (both unique constraints on staging keys AND duplicate detection logic in ETL procs)
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
        DECLARE @StagingCount INT = 0;
        DECLARE @UniqueIndexCount INT = 0;
        DECLARE @ProcWithDupLogic INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @StagingCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name LIKE ''%stag%'' OR s.name LIKE ''%land%'' OR s.name LIKE ''%raw%'';

        SELECT @UniqueIndexCount = COUNT(*) FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE i.is_unique = 1 AND (s.name LIKE ''%stag%'' OR s.name LIKE ''%land%'' OR s.name LIKE ''%raw%'');

        IF OBJECT_ID(''sys.sql_modules'') IS NOT NULL
        BEGIN
            SELECT @ProcWithDupLogic = COUNT(DISTINCT p.object_id)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition LIKE ''%GROUP BY%'' AND m.definition LIKE ''%HAVING%''
               OR m.definition LIKE ''%ROW_NUMBER%''
               OR m.definition LIKE ''%EXCEPT%''
               OR m.definition LIKE ''%duplicate%'';
        END

        IF @StagingCount = 0 SET @DbScore = 0;
        ELSE IF @UniqueIndexCount = 0 AND @ProcWithDupLogic = 0 SET @DbScore = 1;
        ELSE IF @UniqueIndexCount > 0 AND @ProcWithDupLogic > 0 SET @DbScore = 3;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);
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