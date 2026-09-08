-- Checklist: No stringly-typed dates/numbers; correct temporal types
-- Scope: DATABASE
-- Scoring: 3 = no mistyped column; 2 = under 5% of user columns mistyped; 1 = under 25%; 0 = 25% or more, or column metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Column metadata could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @TotalCols INT = 0;
DECLARE @BadCols INT = 0;
DECLARE @StringDates INT = 0;
DECLARE @StringNumbers INT = 0;
DECLARE @LegacyDateTime INT = 0;
DECLARE @FloatMoney INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

DECLARE @Bad TABLE
(
    ColRef NVARCHAR(400) NOT NULL,
    Issue  VARCHAR(20) NOT NULL
);

BEGIN TRY
    SELECT @TotalCols = ISNULL(COUNT(*), 0)
    FROM sys.columns AS c
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0;

    INSERT INTO @Bad (ColRef, Issue)
    SELECT LEFT(ISNULL(SCHEMA_NAME(t.schema_id), 'dbo') + '.' + t.name + '.' + c.name + ' (' + ty.name + ')', 400),
           CASE WHEN ty.name IN ('char', 'varchar', 'nchar', 'nvarchar')
                     AND (c.name LIKE '%date%' OR c.name LIKE '%time%') THEN 'StringDate'
                WHEN ty.name IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'StringNumber'
                WHEN ty.name = 'datetime' THEN 'LegacyDateTime'
                ELSE 'FloatMoney' END
    FROM sys.columns AS c
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
      AND ( (ty.name IN ('char', 'varchar', 'nchar', 'nvarchar')
             AND (c.name LIKE '%date%' OR c.name LIKE '%time%' OR c.name LIKE '%amount%'
                  OR c.name LIKE '%qty%' OR c.name LIKE '%quantity%' OR c.name LIKE '%price%'
                  OR c.name LIKE '%number%' OR c.name LIKE '%[_]id'))
            OR ty.name = 'datetime'
            OR (ty.name IN ('float', 'real')
                AND (c.name LIKE '%amount%' OR c.name LIKE '%price%'
                     OR c.name LIKE '%cost%' OR c.name LIKE '%total%')) );
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

SELECT @BadCols        = ISNULL(COUNT(*), 0),
       @StringDates    = ISNULL(SUM(CASE WHEN Issue = 'StringDate' THEN 1 ELSE 0 END), 0),
       @StringNumbers  = ISNULL(SUM(CASE WHEN Issue = 'StringNumber' THEN 1 ELSE 0 END), 0),
       @LegacyDateTime = ISNULL(SUM(CASE WHEN Issue = 'LegacyDateTime' THEN 1 ELSE 0 END), 0),
       @FloatMoney     = ISNULL(SUM(CASE WHEN Issue = 'FloatMoney' THEN 1 ELSE 0 END), 0)
FROM @Bad;

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), ColRef), ', '), '')
FROM (SELECT TOP (5) ColRef, Issue FROM @Bad ORDER BY Issue, ColRef) AS ex;

SET @Pct = ISNULL(@BadCols * 100.0 / NULLIF(@TotalCols, 0), 0);

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Column metadata in ' + @DatabaseQueried + ' is not readable by the audit login, so temporal and numeric typing could not be assessed.';
END
ELSE IF @TotalCols = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user table columns found in ' + @DatabaseQueried + ', so there is no stringly-typed date or number to report.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @BadCols = 0 THEN 3 WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @BadCols) + ' of ' + CONVERT(NVARCHAR(20), @TotalCols)
                 + ' user column(s) in ' + @DatabaseQueried + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) carry an unsuitable type: ' + CONVERT(NVARCHAR(20), @StringDates)
                 + ' date/time-named column(s) stored as character data, ' + CONVERT(NVARCHAR(20), @StringNumbers)
                 + ' numeric/identifier-named column(s) stored as character data, ' + CONVERT(NVARCHAR(20), @LegacyDateTime)
                 + ' column(s) still using datetime instead of datetime2, and ' + CONVERT(NVARCHAR(20), @FloatMoney)
                 + ' money-like column(s) using float/real. '
                 + CASE WHEN @Examples = '' THEN 'No mistyped column found.' ELSE 'Examples: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;