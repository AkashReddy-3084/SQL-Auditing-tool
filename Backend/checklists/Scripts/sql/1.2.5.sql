-- Checklist: Schema separation used to organize layers/domains (dedicated schemas, not all in dbo)
-- Scope: DATABASE
-- Scoring: 3 = two or more dedicated schemas hold objects and at least 75% of objects sit outside dbo; 2 = two or more dedicated schemas with at least 40% outside dbo, or one schema holding 75%+; 1 = some objects outside dbo but below those thresholds; 0 = every object is in dbo, or the database holds no objects

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Schema distribution in the current database could not be inspected';
DECLARE @Total INT = 0;
DECLARE @DboObjects INT = 0;
DECLARE @NonDbo INT = 0;
DECLARE @UserSchemas INT = 0;
DECLARE @Pct DECIMAL(9, 2) = 0;
DECLARE @SchemaList NVARCHAR(MAX) = N'none';

BEGIN TRY
    SELECT @Total = COUNT(*),
           @DboObjects = ISNULL(SUM(CASE WHEN s.name = N'dbo' THEN 1 ELSE 0 END), 0),
           @NonDbo = ISNULL(SUM(CASE WHEN s.name <> N'dbo' THEN 1 ELSE 0 END), 0),
           @UserSchemas = COUNT(DISTINCT CASE WHEN s.name <> N'dbo' THEN s.schema_id END)
    FROM sys.objects AS o
    JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')
      AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest');

    SET @Pct = ISNULL(100.0 * @NonDbo / NULLIF(CONVERT(DECIMAL(18, 4), @Total), 0), 0);

    SELECT @SchemaList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(s.name, N'=', c.Cnt)), N', '), 500), N'none')
    FROM sys.schemas AS s
    CROSS APPLY (SELECT COUNT(*) AS Cnt
                 FROM sys.objects AS o
                 WHERE o.schema_id = s.schema_id AND o.is_ms_shipped = 0
                   AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')) AS c
    WHERE c.Cnt > 0 AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest');

    SET @Score = CASE
        WHEN @Total = 0 THEN 0
        WHEN @UserSchemas >= 2 AND @Pct >= 75 THEN 3
        WHEN (@UserSchemas >= 2 AND @Pct >= 40) OR (@UserSchemas >= 1 AND @Pct >= 75) THEN 2
        WHEN @NonDbo > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CASE
        WHEN @Total = 0 THEN CONCAT(N'No user object exists in ', DB_NAME(), N', so schema separation could not be assessed')
        WHEN @NonDbo = 0 THEN CONCAT(N'All ', @Total, N' user objects in ', DB_NAME(), N' are in dbo; no dedicated schema is used')
        ELSE CONCAT(@UserSchemas, N' dedicated schema(s) beside dbo; ', @NonDbo, N' of ', @Total,
             N' objects (', @Pct, N'%) live outside dbo, ', @DboObjects,
             N' remain in dbo. Objects per schema: ', @SchemaList) END;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read schema metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
