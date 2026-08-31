-- Checklist: Clear layering defined (staging -> ODS/integration -> dimensional DW -> data marts)
-- Scope: DATABASE
-- Scoring: 3 = all four layers identified as distinct schemas; 2 = two or three layers identified; 1 = one layer identified; 0 = no layer identified or database not readable
-- NOTE: Automated evidence only; full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @HasStaging INT, @HasOds INT, @HasDw INT, @HasMart INT;
    SELECT
        @HasStaging = MAX(CASE WHEN name LIKE 'stg%' OR name LIKE 'staging%' OR name LIKE 'stage%' THEN 1 ELSE 0 END),
        @HasOds = MAX(CASE WHEN name LIKE 'ods%' OR name LIKE 'integration%' OR name = 'int' THEN 1 ELSE 0 END),
        @HasDw = MAX(CASE WHEN name LIKE 'dw%' OR name LIKE 'warehouse%' OR name LIKE 'edw%' THEN 1 ELSE 0 END),
        @HasMart = MAX(CASE WHEN name LIKE 'mart%' OR name LIKE '%mart' OR name LIKE '%marts' THEN 1 ELSE 0 END)
    FROM sys.schemas;

    DECLARE @LayerCount INT = ISNULL(@HasStaging, 0) + ISNULL(@HasOds, 0) + ISNULL(@HasDw, 0) + ISNULL(@HasMart, 0);

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN @LayerCount >= 4 THEN 3 WHEN @LayerCount >= 2 THEN 2 WHEN @LayerCount = 1 THEN 1 ELSE 0 END,
        CONCAT('Layer schemas found: staging=', ISNULL(@HasStaging, 0), ', ods/integration=', ISNULL(@HasOds, 0), ', dw=', ISNULL(@HasDw, 0), ', mart=', ISNULL(@HasMart, 0))
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
            SET @Sql = N'DECLARE @s INT, @o INT, @d INT, @m INT;
SELECT @s = MAX(CASE WHEN name LIKE ''stg%'' OR name LIKE ''staging%'' OR name LIKE ''stage%'' THEN 1 ELSE 0 END),
       @o = MAX(CASE WHEN name LIKE ''ods%'' OR name LIKE ''integration%'' OR name = ''int'' THEN 1 ELSE 0 END),
       @d = MAX(CASE WHEN name LIKE ''dw%'' OR name LIKE ''warehouse%'' OR name LIKE ''edw%'' THEN 1 ELSE 0 END),
       @m = MAX(CASE WHEN name LIKE ''mart%'' OR name LIKE ''%mart'' OR name LIKE ''%marts'' THEN 1 ELSE 0 END)
FROM ' + QUOTENAME(@DbName) + N'.sys.schemas;
SELECT @p_Db,
       CASE WHEN (ISNULL(@s,0)+ISNULL(@o,0)+ISNULL(@d,0)+ISNULL(@m,0)) >= 4 THEN 3
            WHEN (ISNULL(@s,0)+ISNULL(@o,0)+ISNULL(@d,0)+ISNULL(@m,0)) >= 2 THEN 2
            WHEN (ISNULL(@s,0)+ISNULL(@o,0)+ISNULL(@d,0)+ISNULL(@m,0)) = 1 THEN 1
            ELSE 0 END,
       CONCAT(''Layer schemas found: staging='', ISNULL(@s,0), '', ods/integration='', ISNULL(@o,0), '', dw='', ISNULL(@d,0), '', mart='', ISNULL(@m,0));';

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