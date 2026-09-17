-- Checklist: Compression used to reduce storage and IO cost where beneficial
-- Scope: DATABASE
-- Scoring: 3 = at least 75% of table partitions are compressed; 2 = at least 50%; 1 = some compression; 0 = no compression or no tables
-- NOTE: Automated evidence only; whether compression is beneficial requires workload and cost review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Compression metadata could not be evaluated';
DECLARE @Compressed INT = 0;
DECLARE @Total INT = 0;
DECLARE @Ratio DECIMAL(9, 4) = 0;

BEGIN TRY
    SELECT @Compressed = ISNULL(SUM(CASE WHEN p.data_compression > 0 THEN 1 ELSE 0 END), 0),
           @Total = COUNT(*)
    FROM sys.partitions AS p
    WHERE p.object_id IN (SELECT t.object_id FROM sys.tables AS t);

    SET @Ratio = CASE WHEN @Total = 0 THEN 0 ELSE CONVERT(DECIMAL(9, 4), @Compressed) / NULLIF(@Total, 0) END;
    SET @Score = CASE WHEN @Total = 0 THEN 0 WHEN @Ratio >= 0.75 THEN 3 WHEN @Ratio >= 0.50 THEN 2 WHEN @Compressed > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'compressed=' + CONVERT(NVARCHAR(20), @Compressed) + N', total=' + CONVERT(NVARCHAR(20), @Total) + N', compressed_ratio=' + CONVERT(NVARCHAR(20), @Ratio);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read compression metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;