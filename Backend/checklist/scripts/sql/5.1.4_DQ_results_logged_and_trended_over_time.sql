-- Checklist: DQ results logged and trended over time
-- Scope: DATABASE
-- Scoring: 0: No DQ logging tables found. 1: DQ tables found but missing temporal/trending columns. 2: DQ tables with temporal columns found. 3: DQ tables with temporal columns and multiple tables indicating a mature logging framework.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
DECLARE @DqTables TABLE (FullName NVARCHAR(256), HasTemporal BIT);
INSERT INTO @DqTables
SELECT DISTINCT s.name + ''.'' + t.name, 
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.columns c 
        WHERE c.object_id = t.object_id 
          AND (c.name LIKE ''%date%'' OR c.name LIKE ''%time%'' OR c.name LIKE ''%score%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%result%'')
    ) THEN 1 ELSE 0 END
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.name LIKE ''%DQ%'' OR t.name LIKE ''%Quality%'' OR t.name LIKE ''%Validation%'' OR t.name LIKE ''%Audit%'' OR t.name LIKE ''%Log%'';

DECLARE @Count INT = (SELECT COUNT(*) FROM @DqTables);
DECLARE @TemporalCount INT = (SELECT COUNT(*) FROM @DqTables WHERE HasTemporal = 1);
DECLARE @DbScore INT;
DECLARE @DbFinding NVARCHAR(MAX);

IF @Count = 0
BEGIN
    SET @DbScore = 0;
    SET @DbFinding = ''No DQ logging tables found'';
END
ELSE IF @TemporalCount = 0
BEGIN
    SET @DbScore = 1;
    SET @DbFinding = ''DQ tables found but missing temporal/trending columns: '' + ISNULL((SELECT STRING_AGG(FullName, '', '') FROM @DqTables), ''None'');
END
ELSE IF @TemporalCount > 0 AND @Count <= 1
BEGIN
    SET @DbScore = 2;
    SET @DbFinding = ''DQ tables with temporal columns found: '' + ISNULL((SELECT STRING_AGG(FullName, '', '') FROM @DqTables WHERE HasTemporal = 1), ''None'');
END
ELSE
BEGIN
    SET @DbScore = 3;
    SET @DbFinding = ''DQ logging framework detected with temporal tracking: '' + ISNULL((SELECT STRING_AGG(FullName, '', '') FROM @DqTables WHERE HasTemporal = 1), ''None'');
END

INSERT INTO #DbResults (DbName, DbScore, Finding)
VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';

    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR