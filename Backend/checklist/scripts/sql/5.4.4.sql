-- Checklist: Sensitive data: masked/protected where required; format validation applied
-- Scope: DATABASE
-- Scoring: 3 = no sensitive-named columns, or all of them masked/encrypted/classified; 2 = under 5% unprotected, or under 25% with format constraints present; 1 = under 50% unprotected, or some protection/format validation present; 0 = 50%+ unprotected with no format validation

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Sensitive-column protection could not be evaluated in the current database';
DECLARE @SensCols INT = 0;
DECLARE @Protected INT = 0;
DECLARE @FormatChecks INT = 0;
DECLARE @Unprotected NVARCHAR(MAX) = '';
DECLARE @Sources NVARCHAR(200) = 'column encryption';
DECLARE @Parts NVARCHAR(MAX) = '';
DECLARE @Sql NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;

CREATE TABLE #Sens (object_id INT, column_id INT, sch SYSNAME, tbl SYSNAME, col SYSNAME);
CREATE TABLE #Prot (object_id INT, column_id INT);

INSERT INTO #Sens (object_id, column_id, sch, tbl, col)
SELECT c.object_id, c.column_id, s.name, t.name, c.name
FROM sys.columns AS c
JOIN sys.tables AS t ON t.object_id = c.object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (c.name LIKE '%ssn%' OR c.name LIKE '%social[_]security%' OR c.name LIKE '%password%'
       OR c.name LIKE '%passwd%' OR c.name LIKE '%email%' OR c.name LIKE '%phone%'
       OR c.name LIKE '%birth%' OR c.name LIKE '%salary%' OR c.name LIKE '%credit%card%'
       OR c.name LIKE '%card[_]number%' OR c.name LIKE '%iban%' OR c.name LIKE '%passport%'
       OR c.name LIKE '%national[_]id%' OR c.name LIKE '%tax[_]id%' OR c.name LIKE '%account[_]number%');

SELECT @SensCols = COUNT(*) FROM #Sens;

IF OBJECT_ID('sys.masked_columns') IS NOT NULL
BEGIN
    SET @Parts = @Parts + 'SELECT object_id, column_id FROM sys.masked_columns UNION ';
    SET @Sources = 'dynamic data masking, ' + @Sources;
END

IF OBJECT_ID('sys.sensitivity_classifications') IS NOT NULL
BEGIN
    SET @Parts = @Parts + 'SELECT major_id, minor_id FROM sys.sensitivity_classifications UNION ';
    SET @Sources = @Sources + ', sensitivity classification';
END

SET @Parts = @Parts + 'SELECT object_id, column_id FROM sys.columns WHERE encryption_type IS NOT NULL';

BEGIN TRY
    SET @Sql = 'SELECT DISTINCT oid, cid FROM (' + @Parts + ') AS p(oid, cid);';
    INSERT INTO #Prot (object_id, column_id) EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Protection metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SELECT @Protected = COUNT(*)
FROM #Sens AS s
WHERE EXISTS (SELECT 1 FROM #Prot AS p WHERE p.object_id = s.object_id AND p.column_id = s.column_id);

SELECT @Unprotected = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.sch + '.' + s.tbl + '.' + s.col), ', '), 350), '')
FROM #Sens AS s
WHERE NOT EXISTS (SELECT 1 FROM #Prot AS p WHERE p.object_id = s.object_id AND p.column_id = s.column_id);

SELECT @FormatChecks = COUNT(*)
FROM sys.check_constraints AS cc
WHERE EXISTS (SELECT 1 FROM #Sens AS s
              WHERE s.object_id = cc.parent_object_id
                AND (s.column_id = cc.parent_column_id OR cc.definition LIKE '%' + s.col + '%'));

SET @SensCols = ISNULL(@SensCols, 0);
SET @Protected = ISNULL(@Protected, 0);
SET @FormatChecks = ISNULL(@FormatChecks, 0);

DECLARE @GapPct DECIMAL(9,2) = ISNULL(100.0 * (@SensCols - @Protected) / NULLIF(@SensCols, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @SensCols = 0 THEN 3
        WHEN @GapPct = 0 THEN 3
        WHEN @GapPct < 5 OR (@GapPct < 25 AND @FormatChecks > 0) THEN 2
        WHEN @GapPct < 50 OR @Protected > 0 OR @FormatChecks > 0 THEN 1
        ELSE 0 END;

    IF @SensCols = 0
        SET @Finding = 'No sensitive-named columns found in ' + @DatabaseQueried
                     + ' (searched for ssn, password, email, phone, birth, salary, card, iban, passport, tax and account identifiers)';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @Protected, ' of ', @SensCols,
            ' sensitive-named column(s) protected via ', @Sources, ' (',
            CONVERT(NVARCHAR(10), @GapPct), '% unprotected); ', @FormatChecks,
            ' check constraint(s) enforce format on those columns',
            CASE WHEN LEN(@Unprotected) > 0 THEN '; unprotected: ' + @Unprotected ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
