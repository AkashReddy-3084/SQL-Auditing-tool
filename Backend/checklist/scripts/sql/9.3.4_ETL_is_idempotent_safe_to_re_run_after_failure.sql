-- Checklist: ETL is idempotent — safe to re-run after failure
-- Scope: DATABASE
-- Scoring: 0: No DML procedures found or 0% show idempotent patterns. 1: 1-49% show patterns. 2: 50-79% show patterns. 3: >=80% show strong idempotent patterns (TRUNCATE/MERGE/DELETE+INSERT/TRY-CATCH/batch tracking).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    
    BEGIN TRY
        SET @Sql = N'
DECLARE @TotalDml INT = 0;
DECLARE @IdempotentDml INT = 0;
DECLARE @NonCompliantList NVARCHAR(MAX) = N'''';

SELECT @TotalDml = COUNT(*) FROM sys.procedures p
JOIN sys.sql_modules m ON p.object_id = m.object_id
WHERE m.definition IS NOT NULL AND (m.definition LIKE ''''%INSERT%'''' OR m.definition LIKE ''''%UPDATE%'''' OR m.definition LIKE ''''%DELETE%'''' OR m.definition LIKE ''''%MERGE%'''' OR m.definition LIKE ''''%TRUNCATE%'');

SELECT @IdempotentDml = COUNT(*) FROM sys.procedures p
JOIN sys.sql_modules m ON p.object_id = m.object_id
WHERE m.definition IS NOT NULL AND (m.definition LIKE ''''%INSERT%'''' OR m.definition LIKE ''''%UPDATE%'''' OR m.definition LIKE ''''%DELETE%'''' OR m.definition LIKE ''''%MERGE%'''' OR m.definition LIKE ''''%TRUNCATE%'')
  AND (m.definition LIKE ''''%TRUNCATE%'''' OR m.definition LIKE ''''%MERGE%'''' OR m.definition LIKE ''''%DELETE%'''' OR m.definition LIKE ''''%NOT EXISTS%'''' OR m.definition LIKE ''''%TRY%'''' OR m.definition LIKE ''''%CATCH%'''' OR m.definition LIKE ''''%ROLLBACK%'''' OR m.definition LIKE ''''%BATCH_ID%'''' OR m.definition LIKE ''''%LOAD_DATE%'');

SELECT @NonCompliantList = STRING_AGG(QUOTENAME(SCHEMA_NAME(p.schema_id)) + ''''.'' + QUOTENAME(p.name), '''''',''')
FROM sys.procedures p
JOIN sys.sql_modules m ON p.object_id = m.object_id
WHERE m.definition IS NOT NULL AND (m.definition LIKE ''''%INSERT%'''' OR m.definition LIKE ''''%UPDATE%'''' OR m.definition LIKE ''''%DELETE%'''' OR m.definition LIKE ''''%MERGE%'''' OR m.definition LIKE ''''%TRUNCATE%'')
  AND NOT (m.definition LIKE ''''%TRUNCATE%'''' OR m.definition LIKE ''''%MERGE%'''' OR m.definition LIKE ''''%DELETE%'''' OR m.definition LIKE ''''%NOT EXISTS%'''' OR m.definition LIKE ''''%TRY%'''' OR m.definition LIKE ''''%CATCH%'''' OR m.definition LIKE ''''%ROLLBACK%'''' OR m.definition LIKE ''''%BATCH_ID%'''' OR m.definition LIKE ''''%LOAD_DATE%'');

DECLARE @DbScore INT = 0;
DECLARE @DbFinding NVARCHAR(MAX) = N'''';

IF @TotalDml = 0 BEGIN
    SET @DbScore = 0;
    SET @DbFinding = N''''No DML procedures found to evaluate ETL idempotency.'''';
END ELSE BEGIN
    DECLARE @Pct FLOAT = CAST(@IdempotentDml AS FLOAT) / @TotalDml * 100;
    IF @Pct >= 80 SET @DbScore = 3;
    ELSE IF @Pct >= 50 SET @DbScore = 2;
    ELSE IF @Pct > 0 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    SET @DbFinding = N''''Evaluated '''' + CAST(@TotalDml AS NVARCHAR) + N'''' DML procedures. '''' + CAST(@IdempotentDml AS NVARCHAR) + N'''' show idempotent patterns. Non-compliant: '''' + ISNULL(@NonCompliantList, N''''None'''');
END

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (''''' + @DbName + ''''', @DbScore, @DbFinding);
';
        EXEC(@Sql