DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

DECLARE @FileCount INT;
DECLARE @SizesEqual BIT;
DECLARE @AutogrowthFixed BIT;
DECLARE @TotalSizeMB DECIMAL(18,2);

SELECT 
    @FileCount = COUNT(*),
    @SizesEqual = CASE WHEN COUNT(*) > 0 AND MAX(size) = MIN(size) THEN 1 ELSE 0 END,
    @AutogrowthFixed = CASE WHEN COUNT(*) > 0 AND SUM(CASE WHEN is_percent_growth = 0 AND growth > 0 THEN 1 ELSE 0 END) = COUNT(*) THEN 1 ELSE 0 END,
    @TotalSizeMB = SUM(size) * 8.0 / 1024.0
FROM sys.master_files
WHERE database_id = 2 AND type = 0;

IF @TotalSizeMB = 0 OR @FileCount = 0
    SET @Score = 0;
ELSE IF @FileCount >= 4 AND @SizesEqual = 1 AND @AutogrowthFixed = 1 AND @TotalSizeMB >= 1024
    SET @Score = 3;
ELSE IF @FileCount >= 2 AND (@SizesEqual = 1 OR @AutogrowthFixed = 1)
    SET @Score = 2;
ELSE IF @FileCount = 1 OR @SizesEqual = 0 OR @AutogrowthFixed = 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;