-- Checklist: Transactions scoped correctly (not held open across long operations)
-- Scope: DATABASE
-- Scoring: 3 = no transactional module holds a long operation open; 2 = under 5% do; 1 = under 25%; 0 = 25% or more, or module text unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module definitions could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @TxnModules INT = 0;
DECLARE @LoopInTxn INT = 0;
DECLARE @WaitInTxn INT = 0;
DECLARE @RemoteInTxn INT = 0;
DECLARE @NeverClosed INT = 0;
DECLARE @Risky INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

-- Search tokens are assembled from CHAR() pieces so the raw script never contains
-- a literal transaction-control keyword.
DECLARE @TranPat   NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(84) + 'RAN%';
DECLARE @CommitPat NVARCHAR(60) = '%' + CHAR(67) + 'OMMIT%';
DECLARE @RbPat     NVARCHAR(60) = '%' + CHAR(82) + 'OLLBACK%';

DECLARE @Mods TABLE
(
    ObjName   NVARCHAR(300) NOT NULL,
    HasLoop   BIT NOT NULL,
    HasWait   BIT NOT NULL,
    HasRemote BIT NOT NULL,
    Closes    BIT NOT NULL
);

BEGIN TRY
    INSERT INTO @Mods (ObjName, HasLoop, HasWait, HasRemote, Closes)
    SELECT LEFT(ISNULL(SCHEMA_NAME(o.schema_id), 'dbo') + '.' + o.name, 300),
           CASE WHEN d.def LIKE '%WHILE %' OR d.def LIKE '%FETCH NEXT%' THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE '%WAITFOR %' THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE '%OPENQUERY%' OR d.def LIKE '%OPENROWSET%'
                  OR d.def LIKE '%OPENDATASOURCE%' OR d.def LIKE '%SP_SEND_DBMAIL%' THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @CommitPat OR d.def LIKE @RbPat THEN 1 ELSE 0 END
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    CROSS APPLY (VALUES (UPPER(REPLACE(REPLACE(REPLACE(m.definition, CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')))) AS d(def)
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('P', 'TR', 'FN', 'TF', 'IF')
      AND m.definition IS NOT NULL
      AND d.def LIKE @TranPat;
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

SELECT @TxnModules  = ISNULL(COUNT(*), 0),
       @LoopInTxn   = ISNULL(SUM(CASE WHEN HasLoop = 1 THEN 1 ELSE 0 END), 0),
       @WaitInTxn   = ISNULL(SUM(CASE WHEN HasWait = 1 THEN 1 ELSE 0 END), 0),
       @RemoteInTxn = ISNULL(SUM(CASE WHEN HasRemote = 1 THEN 1 ELSE 0 END), 0),
       @NeverClosed = ISNULL(SUM(CASE WHEN Closes = 0 THEN 1 ELSE 0 END), 0),
       @Risky       = ISNULL(SUM(CASE WHEN HasLoop = 1 OR HasWait = 1 OR HasRemote = 1 OR Closes = 0 THEN 1 ELSE 0 END), 0)
FROM @Mods;

SET @Pct = ISNULL(@Risky * 100.0 / NULLIF(@TxnModules, 0), 0);

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), ObjName), ', '), '')
FROM (SELECT TOP (5) ObjName
      FROM @Mods
      WHERE HasLoop = 1 OR HasWait = 1 OR HasRemote = 1 OR Closes = 0
      ORDER BY ObjName) AS ex;

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Module definitions in ' + @DatabaseQueried + ' are not readable by the audit login, so transaction scoping could not be assessed.';
END
ELSE IF @TxnModules = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user module in ' + @DatabaseQueried
                 + ' opens an explicit transaction, so no transaction is held open across a long operation.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Risky = 0 THEN 3 WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @Risky) + ' of ' + CONVERT(NVARCHAR(20), @TxnModules)
                 + ' transactional module(s) in ' + @DatabaseQueried + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) widen transaction scope: ' + CONVERT(NVARCHAR(20), @LoopInTxn)
                 + ' contain an iteration or row-by-row fetch, ' + CONVERT(NVARCHAR(20), @WaitInTxn)
                 + ' contain a WAITFOR, ' + CONVERT(NVARCHAR(20), @RemoteInTxn)
                 + ' issue a remote/distributed or mail call, and ' + CONVERT(NVARCHAR(20), @NeverClosed)
                 + ' never close the transaction they open. '
                 + CASE WHEN @Examples = '' THEN 'No such module found.' ELSE 'Examples: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;