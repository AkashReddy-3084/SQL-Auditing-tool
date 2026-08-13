-- Checklist: Dependencies documented (linked servers, cross-database references)
-- Scope: SERVER
-- Scoring: 0=No documentation found for existing dependencies; 1=1-49% documented; 2=50-89% documented; 3=90-100% documented or no dependencies exist.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalDeps INT = 0;
DECLARE @DocDeps INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @t INT, @d INT;

-- Check Linked Servers (Server-level)
IF OBJECT_ID('sys.servers') IS NOT NULL
BEGIN
    SELECT @TotalDeps += COUNT(*), 
           @DocDeps += SUM(CASE WHEN comment IS NOT NULL OR EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = s.server_id AND ep.class = 10) THEN 1 ELSE 0 END)
    FROM sys.servers s
    WHERE s.server_id > 0;
END

-- Check Cross-Database References (Database-level)
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @t = COUNT(*), 
               @d = SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = sed.referencing_id AND ep.minor_id = 0) THEN 1 ELSE 0 END)
        FROM sys.sql_expression_dependencies sed
        JOIN sys.objects o ON sed.referencing_id = o.object_id
        WHERE sed.referenced_database_name IS NOT NULL;';
        
        EXEC sp_executesql @Sql, N'@t INT OUTPUT, @d INT OUTPUT', @t = @t OUTPUT, @d = @d OUTPUT;
        SET @TotalDeps += ISNULL(@t, 0);
        SET @DocDeps += ISNULL(@d, 0);
    END TRY
    BEGIN CATCH
        -- Skip databases that fail (e.g., offline, restricted access)
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Calculate Score based on documentation ratio
IF @TotalDeps = 0
    SET @Score = 3;
ELSE
BEGIN
    DECLARE @Ratio FLOAT = CAST(@DocDeps AS FLOAT) / @TotalDeps;
    IF @Ratio >= 0.9 SET @Score = 3;
    ELSE IF @Ratio >= 0.5 SET @Score = 2;
    ELSE IF @Ratio > 0 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;