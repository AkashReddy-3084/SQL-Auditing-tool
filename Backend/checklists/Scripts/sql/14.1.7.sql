-- Checklist: Query hints used sparingly and documented where present
-- Scope: DATABASE
-- Scoring: 2 = hinted modules are documented; 1 = hints exist without documentation evidence; 0 = no modules or metadata unavailable
-- NOTE: Automated evidence only; whether hints are necessary and appropriate requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Query-hint metadata could not be evaluated';
DECLARE @Modules INT = 0;
DECLARE @Hinted INT = 0;
DECLARE @HintedDocumented INT = 0;

BEGIN TRY
    SELECT @Modules = COUNT(*),
           @Hinted = ISNULL(SUM(CASE WHEN m.definition LIKE '%OPTION%(%RECOMPILE%' OR m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%FORCESEEK%' OR m.definition LIKE '%FORCE ORDER%' OR m.definition LIKE '%LOOP JOIN%' OR m.definition LIKE '%HASH JOIN%' OR m.definition LIKE '%MAXDOP%' THEN 1 ELSE 0 END), 0),
           @HintedDocumented = ISNULL(SUM(CASE WHEN (m.definition LIKE '%OPTION%(%RECOMPILE%' OR m.definition LIKE '%OPTIMIZE FOR%' OR m.definition LIKE '%FORCESEEK%' OR m.definition LIKE '%FORCE ORDER%') AND (m.definition LIKE '%--%' OR m.definition LIKE '%/*%') THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m;
    SET @Score = CASE WHEN @Hinted = 0 THEN 2 WHEN @HintedDocumented = @Hinted THEN 2 ELSE 1 END;
    SET @Finding = N'modules=' + CONVERT(NVARCHAR(20), @Modules) + N', hinted=' + CONVERT(NVARCHAR(20), @Hinted) + N', hinted_documented=' + CONVERT(NVARCHAR(20), @HintedDocumented);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read query-hint metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;