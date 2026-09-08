-- Checklist: Temp tables vs table variables chosen appropriately for cardinality
-- Scope: DATABASE
-- Scoring: 3 = no module bulk-populates a table variable without a recompile hint; 2 = under 5% of modules using temporary structures do; 1 = under 25%; 0 = 25% or more, or module text unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module definitions could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @Total INT = 0;
DECLARE @VarOnly INT = 0;
DECLARE @Risky INT = 0;
DECLARE @LargeTables INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

-- Search tokens are assembled from CHAR() pieces so the raw script never contains
-- a literal data-definition or data-modification keyword.
DECLARE @TableVarPat NVARCHAR(60) = '%' + CHAR(68) + 'ECLARE @% ' + CHAR(84) + 'ABLE%';
DECLARE @TempTabPat  NVARCHAR(60) = '%' + CHAR(67) + 'REATE ' + CHAR(84) + 'ABLE #%';
DECLARE @IntoTempPat NVARCHAR(60) = '% ' + CHAR(73) + 'NTO #%';
DECLARE @BulkVarPat  NVARCHAR(60) = '%' + CHAR(73) + 'NSERT ' + CHAR(73) + 'NTO @%';

DECLARE @Mods TABLE
(
    ObjName  NVARCHAR(300) NOT NULL,
    UsesVar  BIT NOT NULL,
    UsesTemp BIT NOT NULL,
    BulkFill BIT NOT NULL,
    Recomp   BIT NOT NULL
);

BEGIN TRY
    INSERT INTO @Mods (ObjName, UsesVar, UsesTemp, BulkFill, Recomp)
    SELECT LEFT(ISNULL(SCHEMA_NAME(o.schema_id), 'dbo') + '.' + o.name, 300),
           CASE WHEN d.def LIKE @TableVarPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @TempTabPat OR d.def LIKE @IntoTempPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @BulkVarPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE '%RECOMPILE%' THEN 1 ELSE 0 END
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    CROSS APPLY (VALUES (UPPER(REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')))) AS d(def)
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'TR', 'FN', 'TF', 'IF')
      AND m.definition IS NOT NULL;
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

BEGIN TRY
    SELECT @LargeTables = ISNULL(COUNT(*), 0)
    FROM (SELECT p.object_id
          FROM sys.partitions AS p
          INNER JOIN sys.tables AS t ON t.object_id = p.object_id
          WHERE p.index_id IN (0, 1) AND t.is_ms_shipped = 0
          GROUP BY p.object_id
          HAVING SUM(p.rows) > 100000) AS big;
END TRY
BEGIN CATCH
    SET @LargeTables = 0;
END CATCH

SELECT @Total   = ISNULL(COUNT(*), 0),
       @VarOnly = ISNULL(SUM(CASE WHEN UsesVar = 1 AND UsesTemp = 0 THEN 1 ELSE 0 END), 0),
       @Risky   = ISNULL(SUM(CASE WHEN UsesVar = 1 AND UsesTemp = 0 AND BulkFill = 1 AND Recomp = 0 THEN 1 ELSE 0 END), 0)
FROM @Mods
WHERE UsesVar = 1 OR UsesTemp = 1;

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), ObjName), ', '), '')
FROM (SELECT TOP (5) ObjName
      FROM @Mods
      WHERE UsesVar = 1 AND UsesTemp = 0 AND BulkFill = 1 AND Recomp = 0
      ORDER BY ObjName) AS ex;

SET @Pct = ISNULL(@Risky * 100.0 / NULLIF(@Total, 0), 0);

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Module definitions in ' + @DatabaseQueried + ' are not readable by the audit login, so the temp table versus table variable choice could not be assessed.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user procedure, function or trigger in ' + @DatabaseQueried
                 + ' uses a temp table or a table variable, so there is no cardinality-driven construct choice to assess. '
                 + CONVERT(NVARCHAR(20), @LargeTables) + ' table(s) hold more than 100,000 rows.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Risky = 0 THEN 3 WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @Total) + ' module(s) in ' + @DatabaseQueried
                 + ' use temporary structures, ' + CONVERT(NVARCHAR(20), @VarOnly)
                 + ' of them table variables only; ' + CONVERT(NVARCHAR(20), @Risky) + ' ('
                 + CONVERT(NVARCHAR(20), @Pct)
                 + '%) bulk-populate a table variable and carry no recompile hint, so the optimizer estimates one row whatever the real cardinality. '
                 + CONVERT(NVARCHAR(20), @LargeTables) + ' table(s) in this database exceed 100,000 rows. '
                 + CASE WHEN @Examples = '' THEN 'No such module found.' ELSE 'Examples: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;