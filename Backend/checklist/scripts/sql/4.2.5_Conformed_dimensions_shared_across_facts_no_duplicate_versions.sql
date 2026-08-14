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
        DECLARE @DimCount INT, @FactCount INT, @SharedDimCount INT, @DuplicateDimCount INT;

        SELECT @DimCount = COUNT(*) FROM sys.tables WHERE name LIKE ''%dim%'';
        SELECT @FactCount = COUNT(*) FROM sys.tables WHERE name LIKE ''%fact%'';

        -- Identify isolated or potentially duplicate dimensions (not referenced by any fact table)
        SELECT @DuplicateDimCount = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''%dim%''
          AND NOT EXISTS (
              SELECT 1 FROM sys.foreign_keys fk
              WHERE fk.referenced_object_id = t.object_id
                AND EXISTS (SELECT 1 FROM sys.tables tf WHERE tf.object_id = fk.parent_object_id AND tf.name LIKE ''%fact%'')
          );

        -- Identify dimensions shared across multiple fact tables
        SELECT @SharedDimCount = COUNT(*) FROM (
            SELECT fk.referenced_object_id
            FROM sys.foreign_keys fk
            JOIN sys.tables t_dim ON fk.referenced_object_id = t_dim.object_id
            JOIN sys.tables t_fact ON fk.parent_object_id = t_fact.object_id
            WHERE t_dim.name LIKE ''%dim%''
              AND t_fact.name LIKE ''%fact%''
            GROUP BY fk.referenced_object_id
            HAVING COUNT(DISTINCT fk.parent_object_id) >= 2
        ) s;

        DECLARE @DbScore INT = 0;
        IF @DimCount = 0 OR @FactCount = 0 SET @DbScore = 0;
        ELSE IF @DuplicateDimCount > 0 SET @DbScore = 1;
        ELSE IF @SharedDimCount = @DimCount SET @DbScore = 3;
        ELSE IF @SharedDimCount > 0 SET @DbScore = 2;
        ELSE SET @DbScore = 1;

        INSERT INTO #DbResults VALUES (@p_DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@p_DbName NVARCHAR(256)', @p_DbName = @DbName;
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