-- Checklist: tempdb sized and file-configured correctly (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 3 = multiple files of equal size/growth; 2 = multiple files but inconsistent size/growth; 1 = single data file; 0 = unable to read tempdb metadata

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Unable to read tempdb metadata';

BEGIN TRY
    DECLARE @FileCount INT;
    DECLARE @DistinctSize INT;
    DECLARE @DistinctGrowth INT;
    DECLARE @MinSize INT;
    DECLARE @MaxSize INT;

    -- Count data files for tempdb (database_id = 2)
    SELECT @FileCount = COUNT(*) 
    FROM sys.master_files 
    WHERE database_id = 2 AND type = 0;

    -- Check for size and growth consistency across data files
    SELECT 
        @DistinctSize = COUNT(DISTINCT size),
        @DistinctGrowth = COUNT(DISTINCT growth),
        @MinSize = MIN(size),
        @MaxSize = MAX(size)
    FROM sys.master_files 
    WHERE database_id = 2 AND type = 0;

    IF @FileCount >= 2
    BEGIN
        IF @DistinctSize = 1 AND @DistinctGrowth = 1
        BEGIN
            SET @Score = 3;
            SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR(10)) + ' data files with consistent size and growth.';
        END
        ELSE
        BEGIN
            SET @Score = 2;
            SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR(10)) + ' data files, but size or growth settings are inconsistent (Min size: ' + CAST(@MinSize AS NVARCHAR(20)) + ', Max size: ' + CAST(@MaxSize AS NVARCHAR(20)) + ')';
        END
    END
    ELSE IF @FileCount = 1
    BEGIN
        SET @Score = 1;
        SET @Finding = 'tempdb has only a single data file.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No tempdb data files found.';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = 'Error evaluating tempdb: ' + ERROR_MESSAGE();
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;