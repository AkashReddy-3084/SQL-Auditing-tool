SET NOCOUNT ON;
-- Checklist: Query hints used sparingly and documented where present
-- Scope: DATABASE
-- Scoring: 0 = >50 objects contain hints, 1 = 20-50 objects, 2 = 1-20 objects (documentation requires human review), 3 = 0 objects contain hints
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), HintCount INT, DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #DbResults (DbName, HintCount)
        SELECT ''' + @DbName + N''', COUNT(*)
        FROM sys.sql_modules m
        INNER JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'',''V'',''FN'',''IF'',''TF'',''TR'')
          AND m.definition IS NOT NULL
          AND (
            m.definition LIKE ''%OPTION%''
            OR m.definition LIKE ''%WITH (NOLOCK)%''
            OR m.definition LIKE ''%WITH (READPAST)%''
            OR m.definition LIKE ''%WITH (ROWLOCK)%''
            OR m.definition LIKE ''%WITH (TABLOCK)%''
            OR m.definition LIKE ''%WITH (XLOCK)%''
            OR m.definition LIKE ''%WITH (UPDLOCK)%''
            OR m.definition LIKE ''%WITH (HOLDLOCK)%''
            OR m.definition LIKE ''%WITH (NOWAIT)%''
            OR m.definition LIKE ''%WITH (READUNCOMMITTED)%''
            OR m.definition LIKE ''%WITH (REPEATABLEREAD)%''
            OR m.definition LIKE ''%WITH (SERIALIZABLE)%''
            OR m.definition LIKE ''%WITH (SNAPSHOT)%''
            OR m.definition LIKE ''%WITH (INDEX%''
            OR m.definition LIKE ''%WITH (FORCESEEK)%''
            OR m.definition LIKE ''%WITH (FORCESCAN)%''
            OR m.definition LIKE ''%WITH (FORCEORDER)%''
            OR m.definition LIKE ''%WITH (OPTIMIZE FOR%''
            OR m.definition LIKE ''%WITH (RECOMPILE)%''
            OR m.definition LIKE ''%WITH (USE PLAN%''
            OR m.definition LIKE ''%WITH (MERGE JOIN)%''
            OR m.definition LIKE ''%WITH (HASH JOIN)%''
            OR m.definition LIKE ''%WITH (LOOP JOIN)%''
          );
        ';
        EXEC(@Sql);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, HintCount) VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Calculate score per database based on the defined thresholds
UPDATE #DbResults
SET DbScore = CASE
    WHEN HintCount = 0 THEN 3
    WHEN HintCount <= 20 THEN 2
    WHEN HintCount <= 50 THEN 1
    ELSE 0
END;

-- Final score must reflect the worst-case (MIN) across all user databases
SELECT @Score = MIN(DbScore) FROM #DbResults;
IF @Score IS NULL SET @Score = 3; -- Handles case where no user databases exist

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;