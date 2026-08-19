-- Checklist: tempdb configured appropriately (multiple files, sizing) — SQL Server/MI
-- Scope: SERVER
-- Scoring: 3 = 4+ files of equal size; 2 = 2-3 files of equal size; 1 = multiple files but unequal size; 0 = single file or size mismatch

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Could not determine tempdb configuration';

DECLARE @FileCount INT;
DECLARE @DistinctSizes INT;
DECLARE @MinSize INT;
DECLARE @MaxSize INT;

-- tempdb is always database_id 2
SELECT 
    @FileCount = COUNT(*),
    @DistinctSizes = COUNT(DISTINCT size),
    @MinSize = MIN(size),
    @MaxSize = MAX(size)
FROM sys.master_files 
WHERE database_id = 2 AND type = 0; -- type 0 = ROWS (data files)

IF @FileCount IS NULL OR @FileCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No tempdb data files found';
END
ELSE
BEGIN
    IF @DistinctSizes = 1
    BEGIN
        IF @FileCount >= 4
        BEGIN
            SET @Score = 3;
            SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR(10)) + ' data files of equal size';
        END
        ELSE IF @FileCount >= 2
        BEGIN
            SET @Score = 2;
            SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR(10)) + ' data files of equal size (less than 4)';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'tempdb has only 1 data file';
        END
    END
    ELSE
    BEGIN
        IF @FileCount >= 2
        BEGIN
            SET @Score = 1;
            SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR(10)) + ' data files but sizes are unequal (Min: ' + CAST(@MinSize AS NVARCHAR(20)) + ', Max: ' + CAST(@MaxSize AS NVARCHAR(20)) + ')';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'tempdb has only 1 data file';
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;