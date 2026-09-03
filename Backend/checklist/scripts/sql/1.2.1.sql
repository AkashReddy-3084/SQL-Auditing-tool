-- Checklist: Clear layering defined (staging -> ODS/integration -> dimensional DW -> data marts)
-- Scope: DATABASE
-- Scoring: 3 = three or four of the staging / ODS / DW / mart layers exist as populated schemas; 2 = two layers; 1 = one layer; 0 = no layer schema found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Schema layering in the current database could not be inspected';
DECLARE @Layers INT = 0;
DECLARE @Staging NVARCHAR(MAX) = N'none';
DECLARE @Ods NVARCHAR(MAX) = N'none';
DECLARE @Dw NVARCHAR(MAX) = N'none';
DECLARE @Mart NVARCHAR(MAX) = N'none';
DECLARE @OtherSchemas INT = 0;

CREATE TABLE #Layer (SchemaName SYSNAME NOT NULL, Layer NVARCHAR(10) NOT NULL, ObjectCount INT NOT NULL);

BEGIN TRY
    INSERT INTO #Layer (SchemaName, Layer, ObjectCount)
    SELECT s.name, c.Layer, c.ObjectCount
    FROM sys.schemas AS s
    CROSS APPLY (SELECT COUNT(*) AS ObjectCount
                 FROM sys.objects AS o
                 WHERE o.schema_id = s.schema_id AND o.is_ms_shipped = 0
                   AND o.type IN ('U', 'V')) AS oc
    CROSS APPLY (SELECT CASE
            WHEN LOWER(s.name) IN ('stg', 'stage', 'staging', 'raw', 'land', 'landing', 'bronze', 'src') THEN N'staging'
            WHEN LOWER(s.name) IN ('ods', 'integration', 'int', 'core', 'silver', 'conform') THEN N'ods'
            WHEN LOWER(s.name) IN ('dw', 'dwh', 'edw', 'warehouse', 'dim', 'fact', 'star', 'gold') THEN N'dw'
            WHEN LOWER(s.name) IN ('mart', 'marts', 'dm', 'datamart', 'datamarts', 'rpt', 'report', 'reporting', 'presentation', 'semantic') THEN N'mart'
            ELSE N'other' END AS Layer, oc.ObjectCount AS ObjectCount) AS c
    WHERE c.Layer <> N'other' AND oc.ObjectCount > 0;

    -- a dimensional layer may live in dbo through dim_/fact_ naming instead of a dedicated schema
    IF NOT EXISTS (SELECT 1 FROM #Layer WHERE Layer = N'dw')
    BEGIN
        INSERT INTO #Layer (SchemaName, Layer, ObjectCount)
        SELECT TOP (1) s.name, N'dw', COUNT(*)
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND (t.name LIKE N'dim[_]%' OR t.name LIKE N'fact[_]%' OR t.name LIKE N'd[_]%' OR t.name LIKE N'f[_]%')
        GROUP BY s.name
        ORDER BY COUNT(*) DESC;
    END

    SELECT @Layers = COUNT(DISTINCT Layer) FROM #Layer;
    SELECT @Staging = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SchemaName), N', '), 200), N'none') FROM #Layer WHERE Layer = N'staging';
    SELECT @Ods = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SchemaName), N', '), 200), N'none') FROM #Layer WHERE Layer = N'ods';
    SELECT @Dw = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SchemaName), N', '), 200), N'none') FROM #Layer WHERE Layer = N'dw';
    SELECT @Mart = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SchemaName), N', '), 200), N'none') FROM #Layer WHERE Layer = N'mart';

    SELECT @OtherSchemas = COUNT(DISTINCT o.schema_id)
    FROM sys.objects AS o
    WHERE o.is_ms_shipped = 0 AND o.type IN ('U', 'V')
      AND NOT EXISTS (SELECT 1 FROM #Layer AS l WHERE l.SchemaName = SCHEMA_NAME(o.schema_id));

    SET @Score = CASE WHEN @Layers >= 3 THEN 3 WHEN @Layers = 2 THEN 2 WHEN @Layers = 1 THEN 1 ELSE 0 END;

    SET @Finding = CASE
        WHEN @Layers = 0 THEN CONCAT(N'No staging, ODS, warehouse or mart schema holds objects in ', DB_NAME(),
                                     N'; ', @OtherSchemas, N' other schema(s) hold all tables and views')
        ELSE CONCAT(@Layers, N' of 4 layers present - staging: ', @Staging, N'; ODS/integration: ', @Ods,
                    N'; dimensional DW: ', @Dw, N'; marts: ', @Mart,
                    N'; unclassified schemas holding objects: ', @OtherSchemas) END;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read schema metadata: ' + ERROR_MESSAGE();
END CATCH;

DROP TABLE #Layer;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
