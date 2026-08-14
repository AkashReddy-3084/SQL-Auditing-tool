-- Checklist: Database schema and code source-controlled (SSDT/SQL project or migration scripts)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Migration/version tracking table found, 2=Extended properties reference source control/migration. Max capped at 2 due to indirect/proxy nature.
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
        DECLARE @MigrationTableCount INT = 0;
        DECLARE @ExtPropCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @MigrationTableCount = COUNT(*)
        FROM sys.tables t
        WHERE t.name LIKE ''%Migration%'' OR t.name LIKE ''%Version%'' OR t.name LIKE ''%Deploy%'' OR t.name LIKE ''%Release%'' OR t.name LIKE ''%SchemaHistory%'';

        SELECT @ExtPropCount = COUNT(*)
        FROM sys.extended_properties ep
        WHERE LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%git%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%tfs%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%svn%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%source control%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%migration%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%deploy%'' OR LOWER(CAST(ep.value AS NVARCHAR(MAX))) LIKE ''%ci/cd%'';

        IF @MigrationTableCount > 0 SET @DbScore = 1;
        IF @ExtPropCount > 0 SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
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