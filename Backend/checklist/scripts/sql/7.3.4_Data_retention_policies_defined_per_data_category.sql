-- Checklist: Data retention policies defined per data category
-- Scope: DATABASE
-- Scoring: 0=No evidence; 1=Retention mechanism only; 2=Category mapping only; 3=Both category mapping and retention mechanism
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
        DECLARE @HasCategory BIT = 0;
        DECLARE @HasRetentionMechanism BIT = 0;

        -- Check for category mapping via extended properties
        IF EXISTS (SELECT 1 FROM sys.extended_properties 
                   WHERE name LIKE ''%category%'' OR value LIKE ''%category%'' 
                      OR name LIKE ''%sensitivity%'' OR value LIKE ''%sensitivity%'' 
                      OR name LIKE ''%pii%'' OR value LIKE ''%pii%'')
            SET @HasCategory = 1;

        -- Check for category mapping via data classification (Azure SQL / SQL 2019+)
        IF OBJECT_ID(''sys.classification'') IS NOT NULL
            IF EXISTS (SELECT 1 FROM sys.classification WHERE sensitivity_label IS NOT NULL)
                SET @HasCategory = 1;

        -- Check for retention mechanism via cleanup/archive procedures
        IF EXISTS (SELECT 1 FROM sys.procedures 
                   WHERE name LIKE ''%purge%'' OR name LIKE ''%archive%'' 
                      OR name LIKE ''%cleanup%'' OR name LIKE ''%retention%'')
            SET @HasRetentionMechanism = 1;

        -- Check for retention mechanism via partitioning (time-based retention)
        IF EXISTS (SELECT 1 FROM sys.partition_functions)
            SET @HasRetentionMechanism = 1;

        -- Check for retention mechanism via retention-related extended properties
        IF EXISTS (SELECT 1 FROM sys.extended_properties 
                   WHERE name LIKE ''%retention%'' OR value LIKE ''%retention%'' 
                      OR value LIKE ''%days%'' OR value LIKE ''%months%'' OR value LIKE ''%years%'')
            SET @HasRetentionMechanism = 1;

        DECLARE @DbScore INT = 0;
        IF @HasCategory = 0 AND @HasRetentionMechanism = 0 SET @DbScore = 0;
        ELSE IF @HasCategory = 0 AND @HasRetentionMechanism = 1 SET @DbScore = 1;
        ELSE IF @HasCategory = 1 AND @HasRetentionMechanism = 0 SET @DbScore = 2;
        ELSE IF @HasCategory = 1 AND @HasRetentionMechanism = 1 SET @DbScore = 3;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;