-- Checklist: Retention of historical financial data per policy
-- Scope: DATABASE
-- Scoring: 3 = no financial-named tables, or at least 75% of them retain history (system-versioned, a period, or a paired history/archive table); 2 = at least 40%, or some coverage backed by retention/purge modules; 1 = any coverage, retention module or archive object exists; 0 = financial tables exist with no retention mechanism at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Historical-data retention metadata could not be inspected in this database';
DECLARE @Fin INT = 0;
DECLARE @Cov INT = 0;
DECLARE @Period INT = 0;
DECLARE @Archive INT = 0;
DECLARE @Modules INT = 0;
DECLARE @NoRet NVARCHAR(MAX) = '';
DECLARE @P1 NVARCHAR(60) = '%' + CHAR(80) + 'URGE%';
DECLARE @P2 NVARCHAR(60) = '%RETENTION%';
DECLARE @P3 NVARCHAR(60) = '%ARCHIV%';

WITH fin AS (
    SELECT s.name + '.' + t.name AS FullName,
           t.name AS BaseName,
           t.object_id,
           t.temporal_type,
           t.history_retention_period
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND t.temporal_type <> 1
      AND (t.name LIKE '%invoice%' OR t.name LIKE '%payment%' OR t.name LIKE '%ledger%'
        OR t.name LIKE '%journal%' OR t.name LIKE '%transaction%' OR t.name LIKE '%revenue%'
        OR t.name LIKE '%account%' OR t.name LIKE '%billing%' OR t.name LIKE '%financ%'
        OR t.name LIKE '%gl[_]%')
), cov AS (
    SELECT f.FullName,
           CASE WHEN f.temporal_type = 2 THEN 1
                WHEN EXISTS (SELECT 1 FROM sys.periods AS p WHERE p.object_id = f.object_id) THEN 1
                WHEN EXISTS (SELECT 1 FROM sys.tables AS h
                             WHERE h.name = f.BaseName + '_history'
                                OR h.name = f.BaseName + '_hist'
                                OR h.name = f.BaseName + '_archive') THEN 1
                ELSE 0 END AS HasRetention,
           CASE WHEN f.temporal_type = 2 AND ISNULL(f.history_retention_period, 0) > 0 THEN 1 ELSE 0 END AS HasPeriod
    FROM fin AS f
)
SELECT @Fin = COUNT(*),
       @Cov = ISNULL(SUM(HasRetention), 0),
       @Period = ISNULL(SUM(HasPeriod), 0),
       @NoRet = ISNULL(LEFT(STRING_AGG(CASE WHEN HasRetention = 0 THEN CONVERT(NVARCHAR(MAX), FullName) END, ', '), 400), '')
FROM cov;

SELECT @Archive = COUNT(*)
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (s.name LIKE '%archive%' OR s.name LIKE '%history%'
       OR t.name LIKE '%[_]archive%' OR t.name LIKE '%[_]history%' OR t.temporal_type = 1);

SELECT @Modules = COUNT(*)
FROM sys.sql_modules AS m
JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0
  AND (m.definition LIKE @P1 OR m.definition LIKE @P2 OR m.definition LIKE @P3);

SET @Score = CASE
    WHEN @Fin = 0 THEN 3
    WHEN CONVERT(DECIMAL(9, 4), @Cov) / NULLIF(@Fin, 0) >= 0.75 THEN 3
    WHEN CONVERT(DECIMAL(9, 4), @Cov) / NULLIF(@Fin, 0) >= 0.40 THEN 2
    WHEN @Cov > 0 AND @Modules > 0 THEN 2
    WHEN @Cov > 0 OR @Modules > 0 OR @Archive > 0 THEN 1
    ELSE 0 END;

SET @Finding = CASE
    WHEN @Fin = 0 THEN CONCAT('No financial-named user tables exist in this database; ',
        @Archive, ' archive/history table(s) and ', @Modules, ' retention/purge module(s) were found')
    ELSE CONCAT('Financial-named user tables = ', @Fin,
        ', of which ', @Cov, ' retain history (system-versioned, period-defined or paired with a history/archive table)',
        '; system-versioned tables with an explicit history retention period = ', @Period,
        '; archive/history tables in the database = ', @Archive,
        '; retention or purge modules = ', @Modules,
        CASE WHEN LEN(@NoRet) > 0 THEN '. No retention mechanism on: ' + @NoRet ELSE '' END)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;