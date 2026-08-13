-- Checklist: Each layer has a defined purpose and transformation responsibility
-- Scope: DATABASE
-- Scoring: 0=No identifiable layer schemas; 1=Layer schemas exist but contain zero tables; 2=Layer schemas with tables and transformation procedures but undocumented purpose; 3=Layer schemas with tables, documented purpose (extended properties), and transformation procedures
-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET NOCOUNT ON;
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
        DECLARE @LayerCount INT = 0;
        DECLARE @TableCount INT = 0;
        DECLARE @DocCount INT = 0;
        DECLARE @ProcCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @LayerCount = COUNT(*) FROM sys.schemas
        WHERE name LIKE ''%stag%'' OR name LIKE ''%ods%'' OR name LIKE ''%dw%'' OR name LIKE ''%mart%'' OR name LIKE ''%raw%'' OR name LIKE ''%curated%'' OR name LIKE ''%presentation%'';

        SELECT @TableCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name LIKE ''%stag%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%curated%'' OR s.name LIKE ''%presentation%'';

        SELECT @DocCount = COUNT(*) FROM sys.extended_properties ep
        JOIN sys.schemas s ON ep.major_id = s.schema_id AND ep.minor_id = 0
        WHERE s.name LIKE ''%stag%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%curated%'' OR s.name LIKE ''%presentation%'';

        SELECT @ProcCount = COUNT(*) FROM sys.procedures p
        JOIN sys.schemas s ON p.schema_id = s.schema_id
        WHERE s.name LIKE ''%stag%'' OR s.name LIKE ''%ods%'' OR s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%curated%'' OR s.name LIKE ''%presentation%''
        AND p.name LIKE ''%load%'' OR p.name LIKE ''%transform%'' OR p.name LIKE ''%etl%'' OR p.name LIKE ''%sync%'';

        IF @LayerCount = 0 SET @DbScore = 0;
        ELSE IF @TableCount = 0 SET @DbScore = 1;
        ELSE IF @DocCount > 0 AND @ProcCount > 0 SET @DbScore = 3;
        ELSE SET @DbScore = 2;

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