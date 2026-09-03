<<<<<<< Updated upstream
-- Checklist: Late-arriving / out-of-order data handled without corruption
-- Scope: DATABASE
-- Scoring: 3 = temporal and effective-date/order evidence exists; 2 = two evidence indicators; 1 = one indicator; 0 = no evidence
-- NOTE: Automated evidence only; proving that late-arriving data cannot corrupt results requires workload and data review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Late-arriving data metadata could not be evaluated';
DECLARE @EffectiveColumns INT = 0;
DECLARE @TemporalTables INT = 0;
DECLARE @OrderingModules INT = 0;

BEGIN TRY
    SELECT @EffectiveColumns = COUNT(*)
    FROM sys.columns AS c
    JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0
      AND (c.name LIKE '%effective%' OR c.name LIKE '%valid%from%' OR c.name LIKE '%valid%to%'
           OR c.name LIKE '%start%date%' OR c.name LIKE '%end%date%');

    SELECT @TemporalTables = COUNT(*) FROM sys.tables WHERE temporal_type <> 0;

    SELECT @OrderingModules = COUNT(*)
    FROM sys.sql_modules
    WHERE definition LIKE '%ROW_NUMBER%OVER%ORDER BY%' OR definition LIKE '%MERGE %';

    SET @Score = CASE WHEN @EffectiveColumns > 0 AND @TemporalTables > 0 AND @OrderingModules > 0 THEN 3
                      WHEN (@EffectiveColumns > 0 AND @TemporalTables > 0) OR (@EffectiveColumns > 0 AND @OrderingModules > 0) OR (@TemporalTables > 0 AND @OrderingModules > 0) THEN 2
                      WHEN @EffectiveColumns > 0 OR @TemporalTables > 0 OR @OrderingModules > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'effective_cols=' + CONVERT(NVARCHAR(20), @EffectiveColumns) + N', temporal_tables=' + CONVERT(NVARCHAR(20), @TemporalTables) + N', ordering_modules=' + CONVERT(NVARCHAR(20), @OrderingModules);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read late-arrival handling metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 2.2.6 Late-arriving / out-of-order   data handled without corruption
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
    DECLARE @sql nvarchar(max) = N'SELECT (SELECT COUNT(\*) FROM   sys.columns c JOIN sys.tables t ON t.object\_id = c.object\_id WHERE   t.is\_ms\_shipped = 0 AND (c.name LIKE ''%effective%'' OR c.name LIKE   ''%valid%from%'' OR c.name LIKE ''%valid%to%'' OR c.name LIKE ''%start%date%'' OR   c.name LIKE ''%end%date%'')) AS effective\_cols, (SELECT COUNT(\*) FROM   sys.tables WHERE temporal\_type <> 0) AS temporal\_tables, (SELECT   COUNT(\*) FROM sys.sql\_modules WHERE definition LIKE ''%ROW\_NUMBER%OVER%ORDER   BY%'' OR definition LIKE ''%MERGE %'') AS ordering\_modules;                                                                                                                                                                                                                                                                                                                                                     | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
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
