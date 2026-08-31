SET NOCOUNT ON;

/* 5.1.4 - Data quality results logged and trended over time.
   Strictly read-only proxy check: looks for populated DQ result/log tables
   whose timestamp column retains history across multiple days. */

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();

IF OBJECT_ID('tempdb..#Candidates') IS NOT NULL
    DROP TABLE #Candidates;
IF OBJECT_ID('tempdb..#Measures') IS NOT NULL
    DROP TABLE #Measures;

CREATE TABLE #Candidates
(
    ObjectId    INT      NOT NULL PRIMARY KEY,
    SchemaName  SYSNAME  NOT NULL,
    TableName   SYSNAME  NOT NULL,
    TimeColumn  SYSNAME  NULL,
    ApproxRows  BIGINT   NULL
);

CREATE TABLE #Measures
(
    ObjectId INT          NOT NULL PRIMARY KEY,
    RowCnt   BIGINT       NULL,
    MinTime  DATETIME2(0) NULL,
    MaxTime  DATETIME2(0) NULL
);

/* 1. Candidate data quality result / logging tables, with their best timestamp column. */
INSERT INTO #Candidates (ObjectId, SchemaName, TableName, TimeColumn, ApproxRows)
SELECT  t.object_id,
        s.name,
        t.name,
        tc.ColName,
        ISNULL((SELECT SUM(ps.row_count)
                FROM sys.dm_db_partition_stats AS ps
                WHERE ps.object_id = t.object_id
                  AND ps.index_id IN (0, 1)), 0)
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
OUTER APPLY
(
    SELECT TOP (1) col.name AS ColName
    FROM sys.columns AS col
    INNER JOIN sys.types AS ty
            ON ty.user_type_id = col.user_type_id
    WHERE col.object_id = t.object_id
      AND ty.name IN ('datetime', 'datetime2', 'smalldatetime', 'datetimeoffset', 'date')
    ORDER BY CASE
                WHEN col.name LIKE '%Run%'     THEN 1
                WHEN col.name LIKE '%Exec%'    THEN 2
                WHEN col.name LIKE '%Load%'    THEN 3
                WHEN col.name LIKE '%Check%'   THEN 4
                WHEN col.name LIKE '%Created%' THEN 5
                WHEN col.name LIKE '%Insert%'  THEN 6
                WHEN col.name LIKE '%Date%'    THEN 7
                WHEN col.name LIKE '%Time%'    THEN 8
                ELSE 9
             END,
             col.column_id
) AS tc
WHERE t.is_ms_shipped = 0
  AND t.type = 'U'
  AND t.name NOT LIKE 'sysdiagram%'
  AND (
        t.name LIKE '%DataQuality%'
     OR t.name LIKE '%Data[_]Quality%'
     OR t.name LIKE 'DQ[_]%'
     OR t.name LIKE '%[_]DQ[_]%'
     OR t.name LIKE '%[_]DQ'
     OR t.name LIKE '%Quality%Result%'
     OR t.name LIKE '%Quality%Log%'
     OR t.name LIKE '%Quality%Score%'
     OR t.name LIKE '%Quality%Metric%'
     OR t.name LIKE '%Quality%Check%'
     OR t.name LIKE '%Validation%Result%'
     OR t.name LIKE '%Validation%Log%'
     OR t.name LIKE '%Validation%Error%'
     OR t.name LIKE '%Rule%Result%'
     OR t.name LIKE '%Rule%Execution%'
     OR t.name LIKE '%Rule%Violation%'
     OR t.name LIKE '%Profil%Result%'
     OR t.name LIKE '%DataProfil%'
     OR t.name LIKE '%Reconcil%'
     OR t.name LIKE '%Anomaly%'
     OR t.name LIKE '%Exception%Log%'
      );

/* 2. Row count and retained history window per candidate (bounded to 50 tables). */
DECLARE @Schema SYSNAME, @Table SYSNAME, @Column SYSNAME, @ObjectId INT;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Cnt BIGINT, @MinTime DATETIME2(0), @MaxTime DATETIME2(0);

DECLARE dq_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TOP (50) SchemaName, TableName, TimeColumn, ObjectId
    FROM   #Candidates
    WHERE  TimeColumn IS NOT NULL
    ORDER BY ApproxRows DESC, TableName;

OPEN dq_cursor;
FETCH NEXT FROM dq_cursor INTO @Schema, @Table, @Column, @ObjectId;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Cnt = NULL;
    SET @MinTime = NULL;
    SET @MaxTime = NULL;

    SET @Sql = N'SELECT @c = COUNT_BIG(*), '
             + N'@mn = CONVERT(DATETIME2(0), MIN(' + QUOTENAME(@Column) + N')), '
             + N'@mx = CONVERT(DATETIME2(0), MAX(' + QUOTENAME(@Column) + N')) '
             + N'FROM ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table)
             + N' WITH (READUNCOMMITTED);';

    BEGIN TRY
        EXEC sp_executesql @Sql,
             N'@c BIGINT OUTPUT, @mn DATETIME2(0) OUTPUT, @mx DATETIME2(0) OUTPUT',
             @c = @Cnt OUTPUT, @mn = @MinTime OUTPUT, @mx = @MaxTime OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Cnt = NULL;
        SET @MinTime = NULL;
        SET @MaxTime = NULL;
    END CATCH

    INSERT INTO #Measures (ObjectId, RowCnt, MinTime, MaxTime)
    VALUES (@ObjectId, @Cnt, @MinTime, @MaxTime);

    FETCH NEXT FROM dq_cursor INTO @Schema, @Table, @Column, @ObjectId;
END

CLOSE dq_cursor;
DEALLOCATE dq_cursor;

/* 3. Aggregate the evidence. */
DECLARE @TotalCandidates INT, @LoggedTables INT, @TrendedTables INT, @ShortSpanTables INT, @MaxSpanDays INT;

SELECT @TotalCandidates = COUNT(*) FROM #Candidates;

SELECT @LoggedTables = COUNT(*)
FROM   #Candidates AS c
INNER JOIN #Measures AS m ON m.ObjectId = c.ObjectId
WHERE  c.TimeColumn IS NOT NULL
  AND  ISNULL(m.RowCnt, 0) > 0;

SELECT @TrendedTables = COUNT(*)
FROM   #Candidates AS c
INNER JOIN #Measures AS m ON m.ObjectId = c.ObjectId
WHERE  c.TimeColumn IS NOT NULL
  AND  ISNULL(m.RowCnt, 0) > 0
  AND  ISNULL(DATEDIFF(DAY, m.MinTime, m.MaxTime), 0) >= 7;

SELECT @ShortSpanTables = COUNT(*)
FROM   #Candidates AS c
INNER JOIN #Measures AS m ON m.ObjectId = c.ObjectId
WHERE  c.TimeColumn IS NOT NULL
  AND  ISNULL(m.RowCnt, 0) > 0
  AND  ISNULL(DATEDIFF(DAY, m.MinTime, m.MaxTime), 0) BETWEEN 1 AND 6;

SELECT @MaxSpanDays = MAX(ISNULL(DATEDIFF(DAY, m.MinTime, m.MaxTime), 0))
FROM   #Candidates AS c
INNER JOIN #Measures AS m ON m.ObjectId = c.ObjectId
WHERE  c.TimeColumn IS NOT NULL
  AND  ISNULL(m.RowCnt, 0) > 0;

DECLARE @Evidence NVARCHAR(2000);

SET @Evidence = STUFF((
    SELECT TOP (5) N'; ' + c.SchemaName + N'.' + c.TableName
                 + N' [ts=' + ISNULL(c.TimeColumn, N'none')
                 + N', rows=' + ISNULL(CONVERT(NVARCHAR(20), m.RowCnt), N'n/a')
                 + N', span=' + ISNULL(CONVERT(NVARCHAR(20), DATEDIFF(DAY, m.MinTime, m.MaxTime)), N'n/a') + N'd]'
    FROM   #Candidates AS c
    LEFT JOIN #Measures AS m ON m.ObjectId = c.ObjectId
    ORDER BY CASE WHEN c.TimeColumn IS NULL THEN 1 ELSE 0 END,
             ISNULL(DATEDIFF(DAY, m.MinTime, m.MaxTime), -1) DESC,
             ISNULL(m.RowCnt, -1) DESC,
             c.TableName
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @Evidence = ISNULL(@Evidence, N'none');

/* 4. Score. */
IF @TotalCandidates = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No data quality result or logging tables were found in database ['
                 + @DatabaseQueried
                 + N']. No user tables matched data quality, validation, rule-execution, profiling, reconciliation or anomaly naming patterns, so there is no evidence that DQ results are logged or trended over time.';
END
ELSE IF @TrendedTables > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Data quality results are logged and trended in database ['
                 + @DatabaseQueried + N']. '
                 + CONVERT(NVARCHAR(20), @TrendedTables)
                 + N' of ' + CONVERT(NVARCHAR(20), @TotalCandidates)
                 + N' candidate DQ result table(s) are populated with a timestamp column retaining history over '
                 + CONVERT(NVARCHAR(20), ISNULL(@MaxSpanDays, 0))
                 + N' day(s). Top tables: ' + @Evidence + N'.';
END
ELSE IF @ShortSpanTables > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Data quality results are logged with only a short retained history in database ['
                 + @DatabaseQueried + N']. '
                 + CONVERT(NVARCHAR(20), @ShortSpanTables)
                 + N' populated DQ result table(s) have timestamps spanning only '
                 + CONVERT(NVARCHAR(20), ISNULL(@MaxSpanDays, 0))
                 + N' day(s), below the 7-day threshold used as evidence of sustained trending. Top tables: '
                 + @Evidence + N'.';
END
ELSE IF @LoggedTables > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Data quality result logging exists but is not trended in database ['
                 + @DatabaseQueried + N']. '
                 + CONVERT(NVARCHAR(20), @LoggedTables)
                 + N' populated DQ result table(s) hold rows from a single day only, so no historical trend is retained. Top tables: '
                 + @Evidence + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Data quality result table structures exist but hold no usable history in database ['
                 + @DatabaseQueried + N']. '
                 + CONVERT(NVARCHAR(20), @TotalCandidates)
                 + N' candidate table(s) were found, but none are populated with rows carrying a timestamp column (or they were not readable), so DQ results are not being logged and trended. Candidates: '
                 + @Evidence + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result              AS Result,
       @Score               AS Score,
       @DatabaseQueried     AS DatabaseQueried,
       LEFT(@Finding, 4000) AS Finding;

IF OBJECT_ID('tempdb..#Candidates') IS NOT NULL
    DROP TABLE #Candidates;
IF OBJECT_ID('tempdb..#Measures') IS NOT NULL
    DROP TABLE #Measures;