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