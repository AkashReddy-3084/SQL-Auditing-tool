-- Checklist: Data flow lineage is traceable end-to-end from source to mart
-- Scope: DATABASE
-- Scoring: 0=No lineage evidence; 1=Metadata columns exist but no cross-schema dependencies; 2=Cross-schema dependencies exist; 3=Both cross-schema dependencies and lineage metadata columns found.
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
        DECLARE @DepCount INT = 0;
        DECLARE @MetaCount INT = 0;
        
        SELECT @DepCount = COUNT(DISTINCT referencing_id)
        FROM sys.sql_expression_dependencies
        WHERE referenced_id IS NOT NULL
          AND OBJECTPROPERTY(referenced_id, ''IsMSShipped'') = 0
          AND (
            (LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%stag%'' OR LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%ods%'')
            AND (LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%dw%'' OR LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%mart%'' OR LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%dim%'' OR LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%fact%'')
          )
          OR (
            (LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%dw%'' OR LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%mart%'' OR LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%dim%'' OR LOWER(OBJECT_SCHEMA_NAME(referencing_id)) LIKE ''%fact%'')
            AND (LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%stag%'' OR LOWER(OBJECT_SCHEMA_NAME(referenced_id)) LIKE ''%ods%'')
          );
          
        SELECT @MetaCount = COUNT(DISTINCT c.object_id)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        WHERE LOWER(c.name) IN (''source_system'', ''load_date'', ''etl_timestamp'', ''batch_id'', ''lineage_id'', ''source_table'');
        
        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + N''', 
            CASE 
                WHEN @DepCount > 0 AND @MetaCount > 0 THEN 3
                WHEN @DepCount > 0 THEN 2
                WHEN @MetaCount > 0 THEN 1
                ELSE 0
            END);
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;