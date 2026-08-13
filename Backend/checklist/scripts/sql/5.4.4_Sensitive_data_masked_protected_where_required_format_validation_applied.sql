-- Checklist: Sensitive data: masked/protected where required; format validation applied
-- Scope: DATABASE
-- Scoring: 0=No masking/validation evidence; 1=Only sensitivity tags found; 2=Masking OR validation constraints present; 3=Both masking AND validation constraints present
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbNameParam NVARCHAR(256);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @DbNameParam = @DbName;
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @MaskedCount INT = 0;
        DECLARE @CheckCount INT = 0;
        DECLARE @TagCount INT = 0;
        DECLARE @DbScore INT = 0;

        IF OBJECT_ID(''sys.masked_columns'') IS NOT NULL
            SELECT @MaskedCount = COUNT(*) FROM sys.masked_columns;
            
        SELECT @CheckCount = COUNT(*) FROM sys.check_constraints;
        
        SELECT @TagCount = COUNT(*) FROM sys.extended_properties ep
        JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
        WHERE ep.class = 1
        AND ep.name IN (''sensitive'', ''pii'', ''SensitiveData'', ''MS_Description'')
        AND (CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%sensitive%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%pii%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%SSN%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%credit%'');

        IF @MaskedCount > 0 AND @CheckCount > 0 SET @DbScore = 3;
        ELSE IF @MaskedCount > 0 OR @CheckCount > 0 SET @DbScore = 2;
        ELSE IF @TagCount > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbNameParam;
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