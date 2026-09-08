SET NOCOUNT ON;

/* 4.1.5 - Audit columns present where needed (created/modified, source, batch)
   Read-only catalog inspection of every accessible user database. */

DECLARE @DatabaseQueried NVARCHAR(4000) = N'';
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @Finding         NVARCHAR(4000);

DECLARE @DbName          sysname;
DECLARE @Sql             NVARCHAR(MAX);
DECLARE @DbQueriedCount  INT = 0;
DECLARE @TotalTables     INT = 0;
DECLARE @WithCreated     INT = 0;
DECLARE @WithModified    INT = 0;
DECLARE @WithBoth        INT = 0;
DECLARE @WithSource      INT = 0;
DECLARE @WithBatch       INT = 0;
DECLARE @Coverage        DECIMAL(9,2) = 0;
DECLARE @SampleMissing   NVARCHAR(2000) = N'';

IF OBJECT_ID('tempdb..#AuditColumnCoverage') IS NOT NULL
    DROP TABLE #AuditColumnCoverage;

CREATE TABLE #AuditColumnCoverage
(
    DatabaseName sysname NOT NULL,
    SchemaName   sysname NOT NULL,
    TableName    sysname NOT NULL,
    HasCreated   BIT     NOT NULL,
    HasModified  BIT     NOT NULL,
    HasSource    BIT     NOT NULL,
    HasBatch     BIT     NOT NULL
);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #AuditColumnCoverage (DatabaseName, SchemaName, TableName, HasCreated, HasModified, HasSource, HasBatch)
SELECT
    ' + QUOTENAME(@DbName, '''') + N',
    s.name,
    t.name,
    MAX(CASE
            WHEN c.name LIKE ''%creat%''
              OR c.name LIKE ''%inserted%''
              OR c.name LIKE ''ins[_]%''
              OR c.name LIKE ''%date[_]added%''
              OR c.name LIKE ''%added[_]on%''
            THEN 1 ELSE 0
        END),
    MAX(CASE
            WHEN c.name LIKE ''%modif%''
              OR c.name LIKE ''%updat%''
              OR c.name LIKE ''%changed%''
              OR c.name LIKE ''%last[_]write%''
              OR c.name LIKE ''%lastwrite%''
            THEN 1 ELSE 0
        END),
    MAX(CASE
            WHEN c.name LIKE ''%source%''
              OR c.name LIKE ''%src[_]%''
              OR c.name LIKE ''src%''
              OR c.name LIKE ''%origin%''
            THEN 1 ELSE 0
        END),
    MAX(CASE
            WHEN c.name LIKE ''%batch%''
              OR c.name LIKE ''%load[_]id%''
              OR c.name LIKE ''%loadid%''
              OR c.name LIKE ''%load[_]key%''
              OR c.name LIKE ''%etl%''
            THEN 1 ELSE 0
        END)
FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
        ON s.schema_id = t.schema_id
LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.columns AS c
        ON c.object_id = t.object_id
WHERE t.type = ''U''
  AND t.is_ms_shipped = 0
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
  AND t.name <> ''sysdiagrams''
GROUP BY s.name, t.name;';

        EXEC sys.sp_executesql @Sql;

        SET @DbQueriedCount = @DbQueriedCount + 1;

        IF LEN(@DatabaseQueried) < 3800
            SET @DatabaseQueried = CASE
                                       WHEN @DatabaseQueried = N'' THEN @DbName
                                       ELSE @DatabaseQueried + N', ' + @DbName
                                   END;
    END TRY
    BEGIN CATCH
        /* Database unreadable for this login - skipped, not counted as queried. */
        SET @Sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF @DbQueriedCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Score   = 0;
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    SELECT
        @TotalTables  = COUNT(*),
        @WithCreated  = SUM(CASE WHEN HasCreated  = 1 THEN 1 ELSE 0 END),
        @WithModified = SUM(CASE WHEN HasModified = 1 THEN 1 ELSE 0 END),
        @WithBoth     = SUM(CASE WHEN HasCreated  = 1 AND HasModified = 1 THEN 1 ELSE 0 END),
        @WithSource   = SUM(CASE WHEN HasSource   = 1 THEN 1 ELSE 0 END),
        @WithBatch    = SUM(CASE WHEN HasBatch    = 1 THEN 1 ELSE 0 END)
    FROM #AuditColumnCoverage;

    SET @TotalTables  = ISNULL(@TotalTables, 0);
    SET @WithCreated  = ISNULL(@WithCreated, 0);
    SET @WithModified = ISNULL(@WithModified, 0);
    SET @WithBoth     = ISNULL(@WithBoth, 0);
    SET @WithSource   = ISNULL(@WithSource, 0);
    SET @WithBatch    = ISNULL(@WithBatch, 0);

    SET @Coverage = ISNULL(CAST(@WithBoth AS DECIMAL(9,2)) * 100.0 / NULLIF(@TotalTables, 0), 0);

    SELECT @SampleMissing = STUFF((
            SELECT TOP (10) N', ' + a.DatabaseName + N'.' + a.SchemaName + N'.' + a.TableName
            FROM #AuditColumnCoverage AS a
            WHERE a.HasCreated = 0 OR a.HasModified = 0
            ORDER BY a.DatabaseName, a.SchemaName, a.TableName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(2000)'), 1, 2, N'');

    SET @SampleMissing = ISNULL(@SampleMissing, N'(none)');

    IF @TotalTables = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Inspected ' + CONVERT(NVARCHAR(20), @DbQueriedCount)
            + N' accessible user database(s); none contain user tables, so audit columns are not applicable. Databases queried: ' + @DatabaseQueried + N'.';
    END
    ELSE
    BEGIN
        IF @Coverage >= 90.00 AND @WithSource > 0 AND @WithBatch > 0
            SET @Score = 3;
        ELSE IF @Coverage >= 60.00
            SET @Score = 2;
        ELSE IF @Coverage >= 20.00
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding =
              N'Inspected ' + CONVERT(NVARCHAR(20), @DbQueriedCount) + N' accessible user database(s), '
            + CONVERT(NVARCHAR(20), @TotalTables) + N' user table(s). '
            + CONVERT(NVARCHAR(20), @WithBoth) + N' table(s) (' + CONVERT(NVARCHAR(20), @Coverage) + N'%) carry both a created-style and a modified-style audit column; '
            + CONVERT(NVARCHAR(20), @WithCreated) + N' carry a created-style column and ' + CONVERT(NVARCHAR(20), @WithModified) + N' carry a modified-style column. '
            + N'Lineage columns: ' + CONVERT(NVARCHAR(20), @WithSource) + N' table(s) with a source-style column, '
            + CONVERT(NVARCHAR(20), @WithBatch) + N' table(s) with a batch/load-style column. '
            + N'Tables missing created and/or modified columns (up to 10): ' + @SampleMissing + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID('tempdb..#AuditColumnCoverage') IS NOT NULL
    DROP TABLE #AuditColumnCoverage;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;