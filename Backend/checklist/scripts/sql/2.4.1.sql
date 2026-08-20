-- Checklist: Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads
-- Scope: SERVER
-- Scoring: 3 = bulk patterns found; 2 = minimal evidence; 1 = load logic found but not bulk; 0 = no evidence

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No bulk load patterns detected';

DECLARE @BulkCount INT = 0;
DECLARE @LoadCount INT = 0;
DECLARE @Evidence NVARCHAR(MAX) = '';

CREATE TABLE #ProcResults (DbName SYSNAME, IsBulk BIT, IsLoad BIT, ObjName SYSNAME);

-- Search SQL Agent Job Steps
INSERT INTO #ProcResults (DbName, IsBulk, IsLoad, ObjName)
SELECT 'msdb', 
       CASE WHEN (command LIKE '%BULK INSERT%' OR command LIKE '%OPENROWSET(BULK%' OR command LIKE '%bcp%') THEN 1 ELSE 0 END,
       CASE WHEN (command LIKE '%INSERT INTO%' OR command LIKE '%UPDATE%') THEN 1 ELSE 0 END,
       'JobStep ' + CAST(step_id AS VARCHAR(10))
FROM msdb.dbo.sysjobsteps;

-- Search Stored Procedure Definitions across all accessible databases
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #ProcResults (DbName, IsBulk, IsLoad, ObjName)
    SELECT DB_NAME(), 
           CASE WHEN m.definition LIKE '%BULK INSERT%' OR m.definition LIKE '%OPENROWSET(BULK%' THEN 1 ELSE 0 END,
           CASE WHEN m.definition LIKE '%INSERT INTO%' OR m.definition LIKE '%UPDATE%' THEN 1 ELSE 0 END,
           o.name
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id;
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT ' + QUOTENAME(@DbName, '''') + N', 
                CASE WHEN m.definition LIKE ''%BULK INSERT%'' OR m.definition LIKE ''%OPENROWSET(BULK%'' THEN 1 ELSE 0 END,
                CASE WHEN m.definition LIKE ''%INSERT INTO%'' OR m.definition LIKE ''%UPDATE%'' THEN 1 ELSE 0 END,
                o.name
                FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules m
                JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON m.object_id = o.object_id;';

            INSERT INTO #ProcResults (DbName, IsBulk, IsLoad, ObjName)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            -- Ignore access errors
        END CATCH;
        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

-- Aggregate evidence
SELECT @BulkCount = COUNT(*) FROM #ProcResults WHERE IsBulk = 1;
SELECT @LoadCount = COUNT(*) FROM #ProcResults WHERE IsLoad = 1;

SELECT @Evidence = STRING_AGG(DbName + '.' + ObjName, ', ') 
FROM #ProcResults WHERE IsBulk = 1;

IF @BulkCount >= 2
BEGIN
    SET @Score = 3;
    SET @Finding = 'Bulk load patterns found in: ' + @Evidence;
END
ELSE IF @BulkCount = 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Minimal bulk load evidence found in: ' + @Evidence;
END
ELSE IF @LoadCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Standard load patterns found, but no bulk patterns detected';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No evidence of bulk or standard load patterns in analyzed objects';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;