-- Checklist: Parameter sniffing issues identified and mitigated (OPTIMIZE FOR, recompile, etc.)
-- Scope: DATABASE
-- Scoring: 0 = <10% of parameterized procedures use mitigation hints; 1 = 10-49% use hints; 2 = >=50% use hints; 3 = Forced parameterization enabled at database level.
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
DECLARE @TotalProcs INT = 0;
DECLARE @MitigatedProcs INT = 0;
DECLARE @ForcedParam INT = 0;

SELECT @ForcedParam = is_parameterization_forced FROM sys.databases WHERE name = DB_NAME();

SELECT @TotalProcs = COUNT(DISTINCT p.object_id)
FROM sys.procedures p
INNER JOIN sys.parameters par ON p.object_id = par.object_id
WHERE p.is_ms_shipped = 0;

SELECT @MitigatedProcs = COUNT(DISTINCT sm.object_id)
FROM sys.procedures p
INNER JOIN sys.sql_modules sm ON p.object_id = sm.object_id
WHERE p.is_ms_shipped = 0
AND (ISNULL(sm.definition, '''') LIKE ''%OPTION (RECOMPILE)%''
     OR ISNULL(sm.definition, '''') LIKE ''%OPTIMIZE FOR%''
     OR ISNULL(sm.definition, '''') LIKE ''%WITH RECOMPILE%'');

DECLARE @DbScore INT = 0;
IF @ForcedParam = 1 SET @DbScore = 3;
ELSE IF @TotalProcs = 0 SET @DbScore = 3;
ELSE BEGIN
    DECLARE @Pct FLOAT = CAST(@MitigatedProcs AS FLOAT) / CAST(@TotalProcs AS FLOAT);
    IF @Pct >= 0.5 SET @DbScore = 2;
    ELSE IF @Pct >= 0.1 SET @DbScore = 1;
    ELSE SET @DbScore = 0;
END;

INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);
';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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