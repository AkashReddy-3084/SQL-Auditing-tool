-- Checklist: Each layer has a defined purpose and transformation responsibility
-- Scope: DATABASE
-- Scoring: 3 = two or more layer schemas hold tables and at least two of them own transformation modules or carry a documented description; 2 = two or more layer schemas with at least one owning transformation logic or a description; 1 = layer schemas exist but none owns transformation logic or a description; 0 = no layer schema holds objects

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Layer responsibilities in the current database could not be inspected';
DECLARE @LayerSchemas INT = 0;
DECLARE @WithModules INT = 0;
DECLARE @Described INT = 0;
DECLARE @Detail NVARCHAR(MAX) = N'none';

CREATE TABLE #LayerSchema
(
    SchemaName SYSNAME NOT NULL,
    Layer NVARCHAR(10) NOT NULL,
    TableCount INT NOT NULL,
    ModuleCount INT NOT NULL,
    HasDescription INT NOT NULL
);

BEGIN TRY
    INSERT INTO #LayerSchema (SchemaName, Layer, TableCount, ModuleCount, HasDescription)
    SELECT s.name, c.Layer, ISNULL(m.TableCount, 0), ISNULL(m.ModuleCount, 0),
           CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties AS ep
                             WHERE ep.class = 3 AND ep.major_id = s.schema_id) THEN 1 ELSE 0 END
    FROM sys.schemas AS s
    CROSS APPLY (SELECT CASE
            WHEN LOWER(s.name) IN ('stg', 'stage', 'staging', 'raw', 'land', 'landing', 'bronze', 'src') THEN N'staging'
            WHEN LOWER(s.name) IN ('ods', 'integration', 'int', 'core', 'silver', 'conform') THEN N'ods'
            WHEN LOWER(s.name) IN ('dw', 'dwh', 'edw', 'warehouse', 'dim', 'fact', 'star', 'gold') THEN N'dw'
            WHEN LOWER(s.name) IN ('mart', 'marts', 'dm', 'datamart', 'datamarts', 'rpt', 'report', 'reporting', 'presentation', 'semantic') THEN N'mart'
            ELSE N'other' END AS Layer) AS c
    CROSS APPLY (SELECT
            SUM(CASE WHEN o.type = 'U' THEN 1 ELSE 0 END) AS TableCount,
            SUM(CASE WHEN o.type IN ('V', 'P', 'FN', 'IF', 'TF') THEN 1 ELSE 0 END) AS ModuleCount
         FROM sys.objects AS o
         WHERE o.schema_id = s.schema_id AND o.is_ms_shipped = 0) AS m
    WHERE c.Layer <> N'other' AND ISNULL(m.TableCount, 0) + ISNULL(m.ModuleCount, 0) > 0;

    SELECT @LayerSchemas = COUNT(*),
           @WithModules = ISNULL(SUM(CASE WHEN ModuleCount > 0 THEN 1 ELSE 0 END), 0),
           @Described = ISNULL(SUM(CASE WHEN HasDescription = 1 THEN 1 ELSE 0 END), 0)
    FROM #LayerSchema;

    SELECT @Detail = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
               CONCAT(SchemaName, N' [', Layer, N'] tables=', TableCount,
                      N', transform modules=', ModuleCount,
                      N', described=', HasDescription)), N'; '), 600), N'none')
    FROM #LayerSchema;

    SET @Score = CASE
        WHEN @LayerSchemas = 0 THEN 0
        WHEN @LayerSchemas >= 2 AND (@WithModules >= 2 OR @Described >= 2) THEN 3
        WHEN @LayerSchemas >= 2 AND (@WithModules >= 1 OR @Described >= 1) THEN 2
        ELSE 1 END;

    SET @Finding = CASE
        WHEN @LayerSchemas = 0 THEN CONCAT(N'No staging, ODS, warehouse or mart schema holds any object in ', DB_NAME(),
                                           N', so no layer owns a purpose or transformation')
        ELSE CONCAT(@LayerSchemas, N' layer schema(s) found; ', @WithModules,
                    N' own transformation modules and ', @Described,
                    N' carry a documented schema description. Detail: ', @Detail) END;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read schema and module metadata: ' + ERROR_MESSAGE();
END CATCH;

DROP TABLE #LayerSchema;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
