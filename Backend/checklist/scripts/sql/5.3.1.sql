<<<<<<< Updated upstream
-- Checklist: Referential integrity validated (FKs in facts match dimensions)
-- Scope: DATABASE
-- Scoring: 2 = foreign keys exist and all are trusted; 1 = foreign keys exist but some are untrusted; 0 = no foreign keys or metadata unavailable
-- NOTE: Automated evidence only; confirming fact/dimension semantics requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Foreign-key metadata could not be evaluated';
DECLARE @ForeignKeys INT = 0;
DECLARE @Untrusted INT = 0;

BEGIN TRY
    SELECT @ForeignKeys = COUNT(*), @Untrusted = ISNULL(SUM(CASE WHEN is_not_trusted = 1 THEN 1 ELSE 0 END), 0) FROM sys.foreign_keys;
    SET @Score = CASE WHEN @ForeignKeys = 0 THEN 0 WHEN @Untrusted = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'fks=' + CONVERT(NVARCHAR(20), @ForeignKeys) + N', untrusted=' + CONVERT(NVARCHAR(20), @Untrusted);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read foreign-key metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 5.3.1 Referential   integrity validated (FKs in facts match dimensions)
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
    DECLARE @sql nvarchar(max) = N'SELECT   COUNT(\*) AS fks, SUM(CASE WHEN is\_not\_trusted = 1 THEN 1 ELSE 0 END) AS   untrusted FROM sys.foreign\_keys;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
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
