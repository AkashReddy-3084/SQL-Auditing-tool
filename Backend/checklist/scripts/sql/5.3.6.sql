/*
    Checklist Item : 5.3.6 - Unknown/default dimension member usage monitored
    Scope          : DATABASE (executes in the context of the target database)
    Type           : Read-only catalog inspection. No user data or metadata is modified.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @DatabaseQueried SYSNAME = DB_NAME();

IF OBJECT_ID('tempdb..#DimTables') IS NOT NULL DROP TABLE #DimTables;
IF OBJECT_ID('tempdb..#UnknownFlagCols') IS NOT NULL DROP TABLE #UnknownFlagCols;
IF OBJECT_ID('tempdb..#MonitorObjects') IS NOT NULL DROP TABLE #MonitorObjects;

CREATE TABLE #DimTables
(
    SchemaName SYSNAME NOT NULL,
    TableName  SYSNAME NOT NULL,
    ObjectId   INT     NOT NULL
);

CREATE TABLE #UnknownFlagCols
(
    SchemaName SYSNAME NOT NULL,
    TableName  SYSNAME NOT NULL,
    ColumnName SYSNAME NOT NULL
);

CREATE TABLE #MonitorObjects
(
    SchemaName SYSNAME       NOT NULL,
    ObjectName SYSNAME       NOT NULL,
    ObjectType NVARCHAR(60)  NOT NULL,
    MatchBasis NVARCHAR(30)  NOT NULL
);

/* ---------- 1. Dimension tables present in this database ---------- */
INSERT INTO #DimTables (SchemaName, TableName, ObjectId)
SELECT s.name, t.name, t.object_id
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (
        t.name LIKE 'Dim%'
     OR t.name LIKE '%[_]Dim'
     OR t.name LIKE '%[_]Dim[_]%'
     OR t.name LIKE '%Dimension%'
     OR s.name LIKE '%dim%'
      );

/* ---------- 2. Unknown / default / inferred member handling columns ---------- */
INSERT INTO #UnknownFlagCols (SchemaName, TableName, ColumnName)
SELECT d.SchemaName, d.TableName, c.name
FROM #DimTables AS d
INNER JOIN sys.columns AS c ON c.object_id = d.ObjectId
WHERE c.name LIKE '%Unknown%'
   OR c.name LIKE '%Inferred%'
   OR c.name LIKE '%IsDefault%'
   OR c.name LIKE '%DefaultMember%'
   OR c.name LIKE '%IsMissing%'
   OR c.name LIKE '%NotApplicable%'
   OR c.name LIKE '%Placeholder%';

/* ---------- 3. Monitoring objects identified by name ---------- */
INSERT INTO #MonitorObjects (SchemaName, ObjectName, ObjectType, MatchBasis)
SELECT s.name, o.name, o.type_desc, N'ObjectName'
FROM sys.objects AS o
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')
  AND (
        o.name LIKE '%Unknown%Member%'
     OR o.name LIKE '%Member%Unknown%'
     OR o.name LIKE '%Unknown%Usage%'
     OR o.name LIKE '%Unknown%Count%'
     OR o.name LIKE '%Unknown%Monitor%'
     OR o.name LIKE '%DefaultMember%'
     OR o.name LIKE '%Inferred%Member%'
     OR o.name LIKE '%Orphan%'
     OR o.name LIKE '%DataQuality%Unknown%'
     OR o.name LIKE '%DQ[_]%Unknown%'
      );

/* ---------- 4. Monitoring objects identified by module definition ---------- */
INSERT INTO #MonitorObjects (SchemaName, ObjectName, ObjectType, MatchBasis)
SELECT s.name, o.name, o.type_desc, N'ModuleDefinition'
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o ON o.object_id = m.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('V', 'P', 'FN', 'IF', 'TF')
  AND (
        m.definition LIKE N'%Unknown Member%'
     OR m.definition LIKE N'%UnknownMember%'
     OR m.definition LIKE N'%Unknown%Dim%'
     OR m.definition LIKE N'%Inferred Member%'
     OR m.definition LIKE N'%Default Member%'
      )
  AND NOT EXISTS
      (
          SELECT 1
          FROM #MonitorObjects AS x
          WHERE x.SchemaName = s.name
            AND x.ObjectName = o.name
      );

/* ---------- 5. Which monitoring objects retain history (date + numeric measure) ---------- */
DECLARE @DimTableCount           INT = (SELECT COUNT(*) FROM #DimTables);
DECLARE @UnknownFlagColCount     INT = (SELECT COUNT(*) FROM #UnknownFlagCols);
DECLARE @MonitorObjectCount      INT = (SELECT COUNT(*) FROM #MonitorObjects);
DECLARE @MonitorHistoryCount     INT = 0;

SELECT @MonitorHistoryCount = COUNT(*)
FROM #MonitorObjects AS m
INNER JOIN sys.tables AS t
        ON t.name = m.ObjectName
       AND SCHEMA_NAME(t.schema_id) = m.SchemaName
WHERE m.ObjectType = N'USER_TABLE'
  AND EXISTS
      (
          SELECT 1
          FROM sys.columns AS c
          INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
          WHERE c.object_id = t.object_id
            AND ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
      )
  AND EXISTS
      (
          SELECT 1
          FROM sys.columns AS c2
          INNER JOIN sys.types AS ty2 ON ty2.user_type_id = c2.user_type_id
          WHERE c2.object_id = t.object_id
            AND ty2.name IN ('int', 'bigint', 'smallint', 'tinyint', 'decimal', 'numeric', 'float', 'real', 'money')
      );

/* ---------- 6. Sample evidence ---------- */
DECLARE @SampleMonitors NVARCHAR(1000);
DECLARE @SampleFlagCols NVARCHAR(1000);

SELECT @SampleMonitors = STUFF(
    (
        SELECT TOP (5) N', ' + q.SchemaName + N'.' + q.ObjectName + N' (' + q.ObjectType + N')'
        FROM (SELECT DISTINCT SchemaName, ObjectName, ObjectType FROM #MonitorObjects) AS q
        ORDER BY q.SchemaName, q.ObjectName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

SELECT @SampleFlagCols = STUFF(
    (
        SELECT TOP (5) N', ' + q.SchemaName + N'.' + q.TableName + N'.' + q.ColumnName
        FROM (SELECT DISTINCT SchemaName, TableName, ColumnName FROM #UnknownFlagCols) AS q
        ORDER BY q.SchemaName, q.TableName, q.ColumnName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

SET @SampleMonitors = ISNULL(@SampleMonitors, N'none');
SET @SampleFlagCols = ISNULL(@SampleFlagCols, N'none');

/* ---------- 7. Scoring ---------- */
DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(4000);

IF @DimTableCount = 0
    SET @Score = 0;
ELSE IF @MonitorHistoryCount > 0
    SET @Score = 3;
ELSE IF @MonitorObjectCount > 0
    SET @Score = 2;
ELSE IF @UnknownFlagColCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SET @Finding =
      N'Dimension tables detected: ' + CAST(@DimTableCount AS NVARCHAR(20))
    + N'. Unknown/default/inferred member columns: ' + CAST(@UnknownFlagColCount AS NVARCHAR(20))
    + N' (' + @SampleFlagCols + N')'
    + N'. Unknown/default member monitoring objects: ' + CAST(@MonitorObjectCount AS NVARCHAR(20))
    + N' (' + @SampleMonitors + N')'
    + N'. Monitoring objects retaining history (date + numeric measure): ' + CAST(@MonitorHistoryCount AS NVARCHAR(20))
    + N'. '
    + CASE
          WHEN @DimTableCount = 0
              THEN N'No dimension tables were found in this database, so unknown/default dimension member usage monitoring could not be evidenced here.'
          WHEN @Score = 3
              THEN N'Unknown/default dimension member usage is monitored and the results are retained over time, allowing trend analysis.'
          WHEN @Score = 2
              THEN N'Monitoring logic for unknown/default dimension members exists, but no object retains historical counts, so usage cannot be trended.'
          WHEN @Score = 1
              THEN N'Dimension tables carry unknown/default member handling columns, but no object monitors how often those members are used.'
          ELSE N'No unknown/default dimension member handling or monitoring artifacts were found in this database.'
      END;

SELECT
      @Result          AS Result
    , @Score           AS Score
    , @DatabaseQueried AS DatabaseQueried
    , @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DimTables') IS NOT NULL DROP TABLE #DimTables;
IF OBJECT_ID('tempdb..#UnknownFlagCols') IS NOT NULL DROP TABLE #UnknownFlagCols;
IF OBJECT_ID('tempdb..#MonitorObjects') IS NOT NULL DROP TABLE #MonitorObjects;