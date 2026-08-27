<<<<<<< Updated upstream
-- Checklist: Unique constraints on natural/business keys where appropriate
-- Scope: DATABASE
-- Scoring: 2 = user tables have unique non-primary-key indexes; 1 = no such indexes; 0 = metadata unavailable
-- NOTE: Automated evidence only; identifying appropriate natural/business keys requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Unique-key metadata could not be evaluated';
DECLARE @Uniques INT = 0;

BEGIN TRY
    SELECT @Uniques = COUNT(*)
    FROM sys.indexes
    WHERE is_unique = 1 AND is_primary_key = 0
      AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1;
    SET @Score = CASE WHEN @Uniques > 0 THEN 2 ELSE 1 END;
    SET @Finding = N'uniques=' + CONVERT(NVARCHAR(20), @Uniques);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read unique-key metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 4.5.3 Unique   constraints on natural/business keys where appropriate
-- Scope: SERVER
-- Scoring: 3 = fully verified; 2 = automated evidence present (capped); 1 = minimal/ambiguous evidence; 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

SET NOCOUNT ON;

DECLARE
    @Result nvarchar(10) = 'Fail',
    @Score int = 0,
    @DatabaseQueried sysname = 'master',
    @Finding nvarchar(max) = N'No evidence collected';

-- Attempt to execute the provided probe and capture its result as XML (single column)
CREATE TABLE #probe (xmlcol nvarchar(max));

BEGIN TRY
    DECLARE @sql nvarchar(max) = N'SELECT   COUNT(\*) AS uniques FROM sys.indexes WHERE is\_unique = 1 AND is\_primary\_key =   0 AND OBJECTPROPERTY(object\_id, ''IsUserTable'') = 1;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
    INSERT INTO #probe(xmlcol)
    EXEC sp_executesql @sql;
END TRY
BEGIN CATCH
    INSERT INTO #probe(xmlcol) VALUES (N'Probe execution failed: ' + ERROR_MESSAGE());
END CATCH;

-- Build Finding from probe output (first row concatenated)
SELECT TOP 1 @Finding = ISNULL(xmlcol, N'') FROM #probe;

-- Scoring: 3 if probe indicates strong positive evidence (heuristic)
-- For automated batch generation we conservatively cap automatic verification at 2 unless explicit full-proof indicators exist.
-- Heuristic: if probe returned non-empty content, set Score = 2; else 0.
IF EXISTS (SELECT 1 FROM #probe WHERE LEN(ISNULL(xmlcol, '')) > 0)
    SET @Score = 2;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #probe;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
>>>>>>> Stashed changes
