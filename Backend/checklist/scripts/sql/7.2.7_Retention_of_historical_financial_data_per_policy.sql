-- Checklist: Retention of historical financial data per policy
-- Scope: DATABASE
-- Scoring: 0=No retention artifacts; 1=Only retention-related columns (weak proxy); 2=Partitioning OR archival schemas found; 3=Both partitioning AND archival schemas found (strong technical evidence, requires human policy validation)
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
        DECLARE @PartCount INT = 0;
        DECLARE @ArchiveSchemaCount INT = 0;
        DECLARE @RetentionColCount INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @PartCount = COUNT(*) FROM sys.partition_functions;
        SELECT @ArchiveSchemaCount = COUNT(*) FROM sys.schemas WHERE name LIKE ''%archive%'' OR name LIKE ''%hist%'' OR name LIKE ''%retention%'' OR name LIKE ''%old%'';
        SELECT @RetentionColCount = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%retention%'' OR c.name LIKE ''%archive%'' OR c.name LIKE ''%history%'';

        IF @PartCount > 0 AND @ArchiveSchemaCount > 0 SET @DbScore = 3;
        ELSE IF @PartCount > 0 OR @ArchiveSchemaCount > 0 SET @DbScore = 2;
        ELSE IF @RetentionColCount > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC(@Sql);
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.