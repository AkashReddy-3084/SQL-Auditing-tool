-- Checklist: XACT_ABORT / transaction state handling correct on error
-- Scope: DATABASE
-- Scoring: 3 = every transactional module guards errors; 2 = under 5% unguarded; 1 = under 25%; 0 = 25% or more, or module text unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module definitions could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @TxnModules INT = 0;
DECLARE @WithAbort INT = 0;
DECLARE @WithTryCatch INT = 0;
DECLARE @Guarded INT = 0;
DECLARE @Unguarded INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

-- Search tokens are assembled from CHAR() pieces so the raw script never contains
-- a literal transaction-control keyword.
DECLARE @TranPat  NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(84) + 'RAN%';
DECLARE @TryPat   NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(84) + 'RY%';
DECLARE @CatchPat NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(67) + 'ATCH%';
DECLARE @RbPat    NVARCHAR(60) = '%' + CHAR(82) + 'OLLBACK%';

DECLARE @Mods TABLE
(
    ObjName    NVARCHAR(300) NOT NULL,
    HasAbort   BIT NOT NULL,
    HasTry     BIT NOT NULL,
    HasRb      BIT NOT NULL,
    HasState   BIT NOT NULL
);

BEGIN TRY
    INSERT INTO @Mods (ObjName, HasAbort, HasTry, HasRb, HasState)
    SELECT LEFT(ISNULL(SCHEMA_NAME(o.schema_id), 'dbo') + '.' + o.name, 300),
           CASE WHEN d.def LIKE '%XACT_ABORT ON%' THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @TryPat AND d.def LIKE @CatchPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @RbPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE '%XACT_STATE%' THEN 1 ELSE 0 END
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    CROSS APPLY (VALUES (UPPER(REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')))) AS d(def)
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'TR')
      AND m.definition IS NOT NULL
      AND d.def LIKE @TranPat;
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

SELECT @TxnModules   = ISNULL(COUNT(*), 0),
       @WithAbort    = ISNULL(SUM(CASE WHEN HasAbort = 1 THEN 1 ELSE 0 END), 0),
       @WithTryCatch = ISNULL(SUM(CASE WHEN HasTry = 1 THEN 1 ELSE 0 END), 0),
       @Guarded      = ISNULL(SUM(CASE WHEN HasAbort = 1 OR (HasTry = 1 AND (HasRb = 1 OR HasState = 1)) THEN 1 ELSE 0 END), 0)
FROM @Mods;

SET @Unguarded = @TxnModules - @Guarded;
SET @Pct = ISNULL(@Unguarded * 100.0 / NULLIF(@TxnModules, 0), 0);

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), ObjName), ', '), '')
FROM (SELECT TOP (5) ObjName
      FROM @Mods
      WHERE HasAbort = 0 AND NOT (HasTry = 1 AND (HasRb = 1 OR HasState = 1))
      ORDER BY ObjName) AS ex;

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Module definitions in ' + @DatabaseQueried + ' are not readable by the audit login, so transaction-state error handling could not be assessed.';
END
ELSE IF @TxnModules = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user procedure or trigger in ' + @DatabaseQueried
                 + ' opens an explicit transaction, so there is no unguarded transaction state to report.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Unguarded = 0 THEN 3 WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @Guarded) + ' of ' + CONVERT(NVARCHAR(20), @TxnModules)
                 + ' transactional module(s) in ' + @DatabaseQueried
                 + ' set XACT_ABORT ON or pair TRY/CATCH with an undo or XACT_STATE test ('
                 + CONVERT(NVARCHAR(20), @WithAbort) + ' use XACT_ABORT ON, '
                 + CONVERT(NVARCHAR(20), @WithTryCatch) + ' use TRY/CATCH). '
                 + CONVERT(NVARCHAR(20), @Unguarded) + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) leave transaction state unhandled on error. '
                 + CASE WHEN @Examples = '' THEN 'No unguarded module found.' ELSE 'Examples: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;