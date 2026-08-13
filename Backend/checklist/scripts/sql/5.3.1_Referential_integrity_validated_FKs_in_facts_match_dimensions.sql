-- Checklist: Referential integrity validated (FKs in facts match dimensions)
-- Scope: DATABASE
-- Scoring: 0=No facts or 0% compliance; 1=1-49% facts have enabled FKs to dims; 2=50-99% compliance; 3=100% compliance.
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
        DECLARE @FactCount INT = 0;
        DECLARE @FactWithDimFKCount INT = 0;

        SELECT @FactCount = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''fact%'' OR SCHEMA_NAME(t.schema_id) IN (''fact'', ''Fact'');

        IF @FactCount > 0
        BEGIN
            SELECT @FactWithDimFKCount = COUNT(DISTINCT fk.parent_object_id)
            FROM sys.foreign_keys fk
            JOIN sys.tables t_parent ON fk.parent_object_id = t_parent.object_id
            JOIN sys.tables t_ref ON fk.referenced_object_id = t_ref.object_id
            WHERE (t_parent.name LIKE ''fact%'' OR SCHEMA_NAME(t_parent.schema_id) IN (''fact'', ''Fact''))
              AND (t_ref.name LIKE ''dim%'' OR SCHEMA_NAME(t_ref.schema_id) IN (''dim'', ''Dim''))
              AND fk.is_disabled = 0;
        END

        DECLARE @DbScore INT = 0;
        IF @FactCount = 0 SET @DbScore = 0;
        ELSE
        BEGIN
            DECLARE @Pct FLOAT = CAST(@FactWithDimFKCount AS FLOAT) / @FactCount * 100;
            IF @Pct = 100 SET @DbScore = 3;
            ELSE IF @Pct >= 50 SET @DbScore = 2;
            ELSE IF @Pct > 0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);';
        EXEC sp_executesql @Sql;
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