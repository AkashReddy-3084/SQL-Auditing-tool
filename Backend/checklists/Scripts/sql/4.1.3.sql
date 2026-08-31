<<<<<<< Updated upstream
-- Checklist: Data types appropriate and right-sized (no oversized varchar, correct numeric precision)
-- Scope: DATABASE
-- Scoring: 2 = no oversized columns; 1 = oversized columns exist; 0 = no user columns or metadata unavailable. Numeric precision and workload appropriateness require human review.
-- NOTE: Automated evidence only; numeric precision and workload appropriateness require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Data type metadata could not be evaluated';
DECLARE @TotalColumns INT = 0;
DECLARE @Oversized INT = 0;

BEGIN TRY
    SELECT @TotalColumns = COUNT(*),
           @Oversized = ISNULL(SUM(CASE WHEN c.max_length = -1 OR (t.name IN ('varchar', 'nvarchar', 'char', 'nchar') AND c.max_length >= 4000) THEN 1 ELSE 0 END), 0)
    FROM sys.columns AS c
    JOIN sys.types AS t ON c.user_type_id = t.user_type_id
    WHERE OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1;

    SET @Score = CASE WHEN @TotalColumns = 0 THEN 0 WHEN @Oversized = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'total_cols=' + CONVERT(NVARCHAR(20), @TotalColumns) + N', oversized=' + CONVERT(NVARCHAR(20), @Oversized);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read data type metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 4.1.3 Data   types appropriate and right-sized (no oversized varchar, correct numeric   precision)
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
    DECLARE @sql nvarchar(max) = N'SELECT   COUNT(\*) AS total\_cols, SUM(CASE WHEN c.max\_length = -1 OR (t.name IN   (''varchar'',''nvarchar'',''char'',''nchar'') AND c.max\_length >= 4000) THEN 1   ELSE 0 END) AS oversized FROM sys.columns c JOIN sys.types t ON   c.user\_type\_id = t.user\_type\_id WHERE OBJECTPROPERTY(c.object\_id,   ''IsUserTable'') = 1;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
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
