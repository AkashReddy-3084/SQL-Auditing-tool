/* Checklist 4.2.6 - Date/Time dimension exists with required attributes
   Scope: DATABASE. Strictly read-only - catalog metadata only, no data modification. */
SET NOCOUNT ON;

DECLARE @DatabaseQueried sysname = DB_NAME();
DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(4000);

DECLARE @DateDim TABLE
(
    FullName       NVARCHAR(300) NOT NULL,
    HasDateKey     INT NOT NULL,
    HasFullDate    INT NOT NULL,
    HasYear        INT NOT NULL,
    HasQuarter     INT NOT NULL,
    HasMonth       INT NOT NULL,
    HasDay         INT NOT NULL,
    HasWeek        INT NOT NULL,
    HasDayOfWeek   INT NOT NULL,
    HasFiscal      INT NOT NULL,
    AttributeCount INT NOT NULL,
    RowCountEst    BIGINT NOT NULL
);

INSERT INTO @DateDim
(
    FullName, HasDateKey, HasFullDate, HasYear, HasQuarter, HasMonth,
    HasDay, HasWeek, HasDayOfWeek, HasFiscal, AttributeCount, RowCountEst
)
SELECT
    QUOTENAME(s.name) + N'.' + QUOTENAME(t.name),
    a.HasDateKey,
    a.HasFullDate,
    a.HasYear,
    a.HasQuarter,
    a.HasMonth,
    a.HasDay,
    a.HasWeek,
    a.HasDayOfWeek,
    a.HasFiscal,
    a.HasFullDate + a.HasYear + a.HasQuarter + a.HasMonth + a.HasDay + a.HasWeek + a.HasDayOfWeek,
    ISNULL(r.RowCountEst, 0)
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
CROSS APPLY
(
    SELECT
        HasDateKey = MAX(CASE WHEN c.name LIKE '%datekey%'
                                OR c.name LIKE '%date[_]key%'
                                OR c.name LIKE '%dateid%'
                                OR c.name LIKE '%date[_]id%'
                                OR c.name LIKE '%date[_]sk%'
                                OR c.name LIKE '%datesk%'
                              THEN 1 ELSE 0 END),
        HasFullDate = MAX(CASE WHEN ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime')
                                 OR c.name LIKE '%fulldate%'
                                 OR c.name LIKE '%full[_]date%'
                                 OR c.name LIKE '%calendardate%'
                                 OR c.name LIKE '%actualdate%'
                                 OR c.name = 'Date'
                                 OR c.name = 'DateValue'
                               THEN 1 ELSE 0 END),
        HasYear = MAX(CASE WHEN c.name LIKE '%year%' OR c.name LIKE '%yr%' THEN 1 ELSE 0 END),
        HasQuarter = MAX(CASE WHEN c.name LIKE '%quarter%' OR c.name LIKE '%qtr%' THEN 1 ELSE 0 END),
        HasMonth = MAX(CASE WHEN c.name LIKE '%month%' OR c.name LIKE '%mth%' THEN 1 ELSE 0 END),
        HasDay = MAX(CASE WHEN c.name LIKE '%day%' THEN 1 ELSE 0 END),
        HasWeek = MAX(CASE WHEN c.name LIKE '%week%' OR c.name LIKE '%wk%' THEN 1 ELSE 0 END),
        HasDayOfWeek = MAX(CASE WHEN c.name LIKE '%dayofweek%'
                                  OR c.name LIKE '%day[_]of[_]week%'
                                  OR c.name LIKE '%weekday%'
                                  OR c.name LIKE '%dayname%'
                                  OR c.name LIKE '%day[_]name%'
                                  OR c.name LIKE '%daynumberofweek%'
                                THEN 1 ELSE 0 END),
        HasFiscal = MAX(CASE WHEN c.name LIKE '%fiscal%' OR c.name LIKE 'fy[_]%' THEN 1 ELSE 0 END)
    FROM sys.columns AS c
    INNER JOIN sys.types AS ty
            ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = t.object_id
) AS a
OUTER APPLY
(
    SELECT RowCountEst = SUM(p.rows)
    FROM sys.partitions AS p
    WHERE p.object_id = t.object_id
      AND p.index_id IN (0, 1)
) AS r
WHERE t.is_ms_shipped = 0
  AND t.type = 'U'
  AND
  (
        t.name LIKE 'Dim%Date%'
     OR t.name LIKE 'Dim%Time%'
     OR t.name LIKE 'Dim%Calendar%'
     OR t.name LIKE 'Date%Dim%'
     OR t.name LIKE 'Time%Dim%'
     OR t.name LIKE 'Calendar%Dim%'
     OR t.name LIKE 'D[_]Date%'
     OR t.name LIKE 'D[_]Time%'
     OR t.name IN ('Date', 'Dates', 'Calendar', 'Calendars', 'DateDimension', 'TimeDimension', 'Time', 'DateTable')
  );

DECLARE @DateDimCount   INT;
DECLARE @BestAttr       INT;
DECLARE @UserTableCount INT;
DECLARE @DimModelTables INT;
DECLARE @BestTable      NVARCHAR(300);
DECLARE @BestFiscal     INT;
DECLARE @BestDateKey    INT;
DECLARE @BestRows       BIGINT;
DECLARE @Missing        NVARCHAR(1000);

SELECT @DateDimCount = COUNT(*), @BestAttr = ISNULL(MAX(AttributeCount), 0)
FROM @DateDim;

SELECT @UserTableCount = COUNT(*)
FROM sys.tables
WHERE is_ms_shipped = 0
  AND type = 'U';

SELECT @DimModelTables = COUNT(*)
FROM sys.tables
WHERE is_ms_shipped = 0
  AND type = 'U'
  AND (name LIKE 'Dim%' OR name LIKE 'Fact%' OR name LIKE '%[_]dim' OR name LIKE '%[_]fact');

SELECT TOP (1)
    @BestTable   = FullName,
    @BestFiscal  = HasFiscal,
    @BestDateKey = HasDateKey,
    @BestRows    = RowCountEst,
    @Missing     = ISNULL(STUFF(
                       CASE WHEN HasFullDate  = 0 THEN N', full date' ELSE N'' END +
                       CASE WHEN HasYear      = 0 THEN N', year' ELSE N'' END +
                       CASE WHEN HasQuarter   = 0 THEN N', quarter' ELSE N'' END +
                       CASE WHEN HasMonth     = 0 THEN N', month' ELSE N'' END +
                       CASE WHEN HasDay       = 0 THEN N', day' ELSE N'' END +
                       CASE WHEN HasWeek      = 0 THEN N', week' ELSE N'' END +
                       CASE WHEN HasDayOfWeek = 0 THEN N', day-of-week' ELSE N'' END,
                       1, 2, N''), N'none')
FROM @DateDim
ORDER BY AttributeCount DESC, RowCountEst DESC, FullName ASC;

IF @UserTableCount = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Database [' + @DatabaseQueried + N'] contains no user tables, so a date/time dimension is not applicable. Nothing to remediate in this database; confirm it is not expected to host a dimensional model.';
END
ELSE IF @DateDimCount = 0 AND @DimModelTables = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No date/time dimension table was found in database [' + @DatabaseQueried + N'], and no dimensional-model tables (Dim*/Fact*) were detected across ' + CAST(@UserTableCount AS NVARCHAR(20)) + N' user tables. The database appears to be an OLTP, staging or utility store where a date dimension does not apply.';
END
ELSE IF @DateDimCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Database [' + @DatabaseQueried + N'] contains ' + CAST(@DimModelTables AS NVARCHAR(20)) + N' dimensional-model tables (Dim*/Fact*) but no date/time dimension table was found. All required calendar attributes (full date, year, quarter, month, day, week, day-of-week) are therefore absent.';
END
ELSE IF @BestAttr >= 7
BEGIN
    SET @Score = 3;
    SET @Finding = N'Date/time dimension ' + @BestTable + N' in database [' + @DatabaseQueried + N'] exposes all 7 required attributes (full date, year, quarter, month, day, week, day-of-week). Estimated rows: ' + CAST(ISNULL(@BestRows, 0) AS NVARCHAR(20)) + N'. Surrogate date key present: ' + CASE WHEN @BestDateKey = 1 THEN N'yes' ELSE N'no' END + N'. Fiscal calendar attributes present: ' + CASE WHEN @BestFiscal = 1 THEN N'yes' ELSE N'no' END + N'. Date/time dimension tables found: ' + CAST(@DateDimCount AS NVARCHAR(20)) + N'.';
END
ELSE IF @BestAttr >= 5
BEGIN
    SET @Score = 2;
    SET @Finding = N'Date/time dimension ' + @BestTable + N' in database [' + @DatabaseQueried + N'] provides ' + CAST(@BestAttr AS NVARCHAR(20)) + N' of the 7 required attributes. Missing: ' + @Missing + N'. Estimated rows: ' + CAST(ISNULL(@BestRows, 0) AS NVARCHAR(20)) + N'. Fiscal calendar attributes present: ' + CASE WHEN @BestFiscal = 1 THEN N'yes' ELSE N'no' END + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Date/time dimension ' + @BestTable + N' in database [' + @DatabaseQueried + N'] provides only ' + CAST(@BestAttr AS NVARCHAR(20)) + N' of the 7 required attributes. Missing: ' + @Missing + N'. Estimated rows: ' + CAST(ISNULL(@BestRows, 0) AS NVARCHAR(20)) + N'. The dimension cannot support standard calendar-based analysis.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result           AS Result,
    @Score            AS Score,
    @DatabaseQueried  AS DatabaseQueried,
    @Finding          AS Finding;