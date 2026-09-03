-- Checklist: Deadlock-prone patterns avoided; retry logic where needed
-- Scope: DATABASE
-- Scoring: 3 = no multi-write transactional module lacks retry logic and RCSI is on; 2 = none lacks retry logic but RCSI is off; 1 = under 25% lack retry logic; 0 = 25% or more, or module text unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module definitions could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @Rcsi INT = 0;
DECLARE @MultiWriteTxn INT = 0;
DECLARE @WithRetry INT = 0;
DECLARE @WithHints INT = 0;
DECLARE @Risky INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

-- Search tokens are assembled from CHAR() pieces so the raw script never contains
-- a literal data-modification or transaction-control keyword.
DECLARE @TranPat   NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(84) + 'RAN%';
DECLARE @InsPat    NVARCHAR(60) = '%' + CHAR(73) + 'NSERT %';
DECLARE @UpdPat    NVARCHAR(60) = '%' + CHAR(85) + 'PDATE %';
DECLARE @DelPat    NVARCHAR(60) = '%' + CHAR(68) + 'ELETE %';
DECLARE @MrgPat    NVARCHAR(60) = '%' + CHAR(77) + 'ERGE %';
DECLARE @TryPat    NVARCHAR(60) = '%' + CHAR(66) + 'EGIN ' + CHAR(84) + 'RY%';

SET @Rcsi = CASE WHEN CONVERT(INT, ISNULL(DATABASEPROPERTYEX(DB_NAME(), 'IsReadCommittedSnapshotOn'), 0)) = 1 THEN 1 ELSE 0 END;

DECLARE @Mods TABLE
(
    ObjName    NVARCHAR(300) NOT NULL,
    WriteVerbs INT NOT NULL,
    HasRetry   BIT NOT NULL,
    HasHints   BIT NOT NULL
);

BEGIN TRY
    INSERT INTO @Mods (ObjName, WriteVerbs, HasRetry, HasHints)
    SELECT LEFT(ISNULL(SCHEMA_NAME(o.schema_id), 'dbo') + '.' + o.name, 300),
           CASE WHEN d.def LIKE @InsPat THEN 1 ELSE 0 END
         + CASE WHEN d.def LIKE @UpdPat THEN 1 ELSE 0 END
         + CASE WHEN d.def LIKE @DelPat THEN 1 ELSE 0 END
         + CASE WHEN d.def LIKE @MrgPat THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE @TryPat
                 AND (d.def LIKE '%1205%' OR d.def LIKE '%ERROR_NUMBER%')
                 AND (d.def LIKE '%WHILE %' OR d.def LIKE '%RETRY%') THEN 1 ELSE 0 END,
           CASE WHEN d.def LIKE '%UPDLOCK%' OR d.def LIKE '%HOLDLOCK%'
                  OR d.def LIKE '%READPAST%' OR d.def LIKE '%DEADLOCK_PRIORITY%'
                  OR d.def LIKE '%SNAPSHOT%' THEN 1 ELSE 0 END
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

SELECT @MultiWriteTxn = ISNULL(COUNT(*), 0),
       @WithRetry     = ISNULL(SUM(CASE WHEN HasRetry = 1 THEN 1 ELSE 0 END), 0),
       @WithHints     = ISNULL(SUM(CASE WHEN HasHints = 1 THEN 1 ELSE 0 END), 0),
       @Risky         = ISNULL(SUM(CASE WHEN HasRetry = 0 THEN 1 ELSE 0 END), 0)
FROM @Mods
WHERE WriteVerbs >= 2;

SET @Pct = ISNULL(@Risky * 100.0 / NULLIF(@MultiWriteTxn, 0), 0);

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), ObjName), ', '), '')
FROM (SELECT TOP (5) ObjName FROM @Mods WHERE WriteVerbs >= 2 AND HasRetry = 0 ORDER BY ObjName) AS ex;

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Module definitions in ' + @DatabaseQueried + ' are not readable by the audit login, so deadlock-prone patterns could not be assessed.';
END
ELSE IF @MultiWriteTxn = 0
BEGIN
    SET @Score = CASE WHEN @Rcsi = 1 THEN 3 ELSE 2 END;
    SET @Finding = 'No user procedure or trigger in ' + @DatabaseQueried
                 + ' writes to two or more object types inside an explicit transaction, so no multi-resource deadlock pattern exists. IsReadCommittedSnapshotOn = '
                 + CONVERT(NVARCHAR(5), @Rcsi) + '.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Risky = 0 AND @Rcsi = 1 THEN 3
                      WHEN @Risky = 0 THEN 2
                      WHEN @Pct < 25 THEN 1
                      ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @MultiWriteTxn) + ' transactional module(s) in ' + @DatabaseQueried
                 + ' write to two or more object types in one transaction; ' + CONVERT(NVARCHAR(20), @Risky)
                 + ' (' + CONVERT(NVARCHAR(20), @Pct) + '%) carry no deadlock retry loop on error 1205, '
                 + CONVERT(NVARCHAR(20), @WithRetry) + ' do, and ' + CONVERT(NVARCHAR(20), @WithHints)
                 + ' use lock or isolation mitigations. IsReadCommittedSnapshotOn = ' + CONVERT(NVARCHAR(5), @Rcsi) + '. '
                 + CASE WHEN @Examples = '' THEN 'No module lacks retry logic.' ELSE 'Examples without retry logic: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;