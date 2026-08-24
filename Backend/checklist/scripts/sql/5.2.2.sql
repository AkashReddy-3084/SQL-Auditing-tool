-- Checklist: Completeness: all expected sources/batches received
-- Scope: DATABASE
-- Scoring: 3 = control/batch table with both expected and received columns; 2 = only one of the two found; 1 = control/batch table exists but neither found; 0 = no control/batch tracking table found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @ControlTableCount INT, @HasExpected INT, @HasReceived INT;

    SELECT @ControlTableCount = COUNT(*) FROM sys.tables
    WHERE name LIKE '%batch_control%' OR name LIKE '%etl_control%' OR name LIKE '%source_control%' OR name LIKE '%load_control%';

    SELECT @HasExpected = MAX(CASE WHEN c.name LIKE '%expected%' THEN 1 ELSE 0 END),
           @HasReceived = MAX(CASE WHEN c.name LIKE '%received%' OR c.name LIKE '%actual%' THEN 1 ELSE 0 END)
    FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE t.name LIKE '%batch_control%' OR t.name LIKE '%etl_control%' OR t.name LIKE '%source_control%' OR t.name LIKE '%load_control%';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@ControlTableCount,0) = 0 THEN 0
             WHEN ISNULL(@HasExpected,0) = 1 AND ISNULL(@HasReceived,0) = 1 THEN 3
             WHEN ISNULL(@HasExpected,0) = 1 OR ISNULL(@HasReceived,0) = 1 THEN 2
             ELSE 1 END,
        CASE WHEN ISNULL(@ControlTableCount,0) = 0 THEN 'No control/batch tracking table found'
             ELSE CONCAT('Control/batch tables = ', @ControlTableCount, ', has expected column = ', ISNULL(@HasExpected,0), ', has received column = ', ISNULL(@HasReceived,0)) END
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @ct INT, @he INT, @hr INT;
SELECT @ct = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables
WHERE name LIKE ''%batch_control%'' OR name LIKE ''%etl_control%'' OR name LIKE ''%source_control%'' OR name LIKE ''%load_control%'';
SELECT @he = MAX(CASE WHEN c.name LIKE ''%expected%'' THEN 1 ELSE 0 END),
       @hr = MAX(CASE WHEN c.name LIKE ''%received%'' OR c.name LIKE ''%actual%'' THEN 1 ELSE 0 END)
FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON t.object_id = c.object_id
WHERE t.name LIKE ''%batch_control%'' OR t.name LIKE ''%etl_control%'' OR t.name LIKE ''%source_control%'' OR t.name LIKE ''%load_control%'';
SELECT @p_Db,
       CASE WHEN ISNULL(@ct,0) = 0 THEN 0
            WHEN ISNULL(@he,0) = 1 AND ISNULL(@hr,0) = 1 THEN 3
            WHEN ISNULL(@he,0) = 1 OR ISNULL(@hr,0) = 1 THEN 2
            ELSE 1 END,
       CASE WHEN ISNULL(@ct,0) = 0 THEN ''No control/batch tracking table found''
            ELSE CONCAT(''Control/batch tables = '', @ct, '', has expected column = '', ISNULL(@he,0), '', has received column = '', ISNULL(@hr,0)) END;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;