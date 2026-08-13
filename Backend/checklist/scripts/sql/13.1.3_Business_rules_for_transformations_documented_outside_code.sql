-- Checklist: Business rules for transformations documented outside code
-- Scope: DATABASE
-- Scoring: 0=No proxy evidence found; 1=Minimal extended properties or metadata tables exist; 2=Structured metadata tables and extended properties found (proxy evidence); 3=Not achievable (requires human verification of actual documentation content)
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
        DECLARE @ExtPropCount INT = 0;
        DECLARE @MetaTableCount INT = 0;

        SELECT @ExtPropCount = COUNT(*)
        FROM sys.extended_properties ep
        JOIN sys.objects o ON ep.major_id = o.object_id
        WHERE o.type IN (''U'', ''P'')
          AND (ep.name LIKE ''%rule%'' OR ep.name LIKE ''%description%'' OR ep.name LIKE ''%transformation%'');

        SELECT @MetaTableCount = COUNT(*)
        FROM sys.tables t
        WHERE t.name LIKE ''%rule%'' OR t.name LIKE ''%mapping%'' OR t.name LIKE ''%config%'' OR t.name LIKE ''%metadata%'';

        DECLARE @DbScore INT = 0;
        IF @ExtPropCount > 0 AND @MetaTableCount > 0 SET @DbScore = 2;
        ELSE IF @ExtPropCount > 0 OR @MetaTableCount > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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