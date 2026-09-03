-- Checklist: Fact table grain clearly defined and documented per fact
-- Scope: DATABASE
-- Scoring: 2 = fact tables have metadata and unique-key evidence; 1 = fact tables exist with partial evidence; 0 = no fact tables
-- NOTE: Automated evidence only; grain definitions and documentation require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Fact-table metadata could not be evaluated';
DECLARE @FactTables INT = 0;
DECLARE @DocumentedFacts INT = 0;
DECLARE @FactWithUnique INT = 0;

BEGIN TRY
    SELECT @FactTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND (name LIKE 'Fact%' OR name LIKE '%[_]fact');
    SELECT @DocumentedFacts = COUNT(DISTINCT ep.major_id)
    FROM sys.extended_properties AS ep JOIN sys.tables AS t ON t.object_id = ep.major_id
    WHERE ep.minor_id = 0 AND (t.name LIKE 'Fact%' OR t.name LIKE '%[_]fact');
    SELECT @FactWithUnique = COUNT(*) FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0 AND (t.name LIKE 'Fact%' OR t.name LIKE '%[_]fact')
      AND EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = t.object_id AND i.is_unique = 1);
    SET @Score = CASE WHEN @FactTables = 0 THEN 0 WHEN @DocumentedFacts = @FactTables AND @FactWithUnique = @FactTables THEN 2 WHEN @DocumentedFacts > 0 OR @FactWithUnique > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'fact_tables=' + CONVERT(NVARCHAR(20), @FactTables) + N', documented_facts=' + CONVERT(NVARCHAR(20), @DocumentedFacts) + N', fact_with_unique=' + CONVERT(NVARCHAR(20), @FactWithUnique);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read fact-table metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;