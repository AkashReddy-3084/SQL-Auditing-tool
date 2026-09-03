-- Checklist: Data compression (row/page/columnstore) applied where beneficial
-- Scope: DATABASE
-- Scoring: 3 = at least 75% of table partitions are compressed; 2 = 50%-74%; 1 = greater than 0% but below 50%; 0 = no compressed partitions or evidence is unavailable
-- NOTE: Automated evidence measures configured compression; whether compression is beneficial for a workload requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Compression evidence unavailable';
DECLARE @CompressedPartitionCount INT = 0;
DECLARE @PartitionCount INT = 0;
DECLARE @CompressedPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT
        @CompressedPartitionCount = ISNULL(SUM(CASE WHEN p.data_compression > 0 THEN 1 ELSE 0 END), 0),
        @PartitionCount = COUNT(*)
    FROM sys.partitions AS p
    WHERE p.object_id IN (SELECT object_id FROM sys.tables);
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @CompressedPercent = CASE
    WHEN @PartitionCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @CompressedPartitionCount / NULLIF(@PartitionCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @PartitionCount = 0 THEN 2
    WHEN @CompressedPercent >= 75.00 THEN 3
    WHEN @CompressedPercent >= 50.00 THEN 2
    WHEN @CompressedPartitionCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'compressed partitions = ', @CompressedPartitionCount,
    N'; total table partitions = ', @PartitionCount,
    N'; compressed percentage = ', @CompressedPercent, N'%',
    CASE WHEN @ReadError = 1 THEN N'; partition metadata could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
