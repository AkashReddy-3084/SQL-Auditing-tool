/* 5.4.3 - String / Text: encoding/collation consistency, bounded lengths, silent-truncation protection.
   Read-only: catalog views only. Temp tables are used to collect per-database results. */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

IF OBJECT_ID('tempdb..#StringQuality') IS NOT NULL
    DROP TABLE #StringQuality;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;

CREATE TABLE #StringQuality
(
    DatabaseName        SYSNAME        NOT NULL,
    DatabaseCollation   NVARCHAR(128)  NULL,
    AnsiWarningsOn      BIT            NULL,
    StringColumns       INT            NULL,
    CollationMismatches INT            NULL,
    MaxLengthColumns    INT            NULL,
    DeprecatedTypes     INT            NULL,
    ErrorText           NVARCHAR(400)  NULL
);

CREATE TABLE #Scored
(
    DatabaseName SYSNAME        NOT NULL,
    DbScore      INT            NOT NULL,
    NotInspected BIT            NOT NULL,
    DbFinding    NVARCHAR(1000) NOT NULL
);

DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Result VARCHAR(20);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DbCount INT;
DECLARE @PassCount INT;
DECLARE @PartialCount INT;
DECLARE @FailCount INT;
DECLARE @ReviewCount INT;
DECLARE @Detail NVARCHAR(MAX);

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: cross-database catalog access is not permitted; evaluate the current database only. */
    BEGIN TRY
        INSERT INTO #StringQuality
            (DatabaseName, DatabaseCollation, AnsiWarningsOn, StringColumns,
             CollationMismatches, MaxLengthColumns, DeprecatedTypes)
        SELECT
            DB_NAME(),
            CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation')),
            (SELECT CONVERT(BIT, d.is_ansi_warnings_on) FROM sys.databases AS d WHERE d.database_id = DB_ID()),
            COUNT(*),
            SUM(CASE WHEN c.collation_name IS NOT NULL
                      AND c.collation_name <> CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation'))
                     THEN 1 ELSE 0 END),
            SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END),
            SUM(CASE WHEN t.name IN ('text', 'ntext') THEN 1 ELSE 0 END)
        FROM sys.columns AS c
        INNER JOIN sys.objects AS o
            ON o.object_id = c.object_id
        INNER JOIN sys.types AS t
            ON t.user_type_id = c.user_type_id
        WHERE o.type = 'U'
          AND o.is_ms_shipped = 0
          AND t.name IN ('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext');
    END TRY
    BEGIN CATCH
        INSERT INTO #StringQuality (DatabaseName, ErrorText)
        VALUES (DB_NAME(), LEFT(ERROR_MESSAGE(), 400));
    END CATCH
END
ELSE
BEGIN
    DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN DbCursor;
    FETCH NEXT FROM DbCursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
SELECT
    @dbn AS DatabaseName,
    CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(@dbn, ''Collation'')) AS DatabaseCollation,
    (SELECT CONVERT(BIT, d.is_ansi_warnings_on) FROM sys.databases AS d WHERE d.name = @dbn) AS AnsiWarningsOn,
    COUNT(*) AS StringColumns,
    SUM(CASE WHEN c.collation_name IS NOT NULL
              AND c.collation_name <> CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(@dbn, ''Collation''))
             THEN 1 ELSE 0 END) AS CollationMismatches,
    SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END) AS MaxLengthColumns,
    SUM(CASE WHEN t.name IN (''text'', ''ntext'') THEN 1 ELSE 0 END) AS DeprecatedTypes
FROM ' + QUOTENAME(@DbName) + N'.sys.columns AS c
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
    ON o.object_id = c.object_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.types AS t
    ON t.user_type_id = c.user_type_id
WHERE o.type = ''U''
  AND o.is_ms_shipped = 0
  AND t.name IN (''char'', ''varchar'', ''nchar'', ''nvarchar'', ''text'', ''ntext'');';

            INSERT INTO #StringQuality
                (DatabaseName, DatabaseCollation, AnsiWarningsOn, StringColumns,
                 CollationMismatches, MaxLengthColumns, DeprecatedTypes)
            EXEC sp_executesql @Sql, N'@dbn SYSNAME', @dbn = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #StringQuality (DatabaseName, ErrorText)
            VALUES (@DbName, LEFT(ERROR_MESSAGE(), 400));
        END CATCH

        FETCH NEXT FROM DbCursor INTO @DbName;
    END

    CLOSE DbCursor;
    DEALLOCATE DbCursor;
END

IF NOT EXISTS (SELECT 1 FROM #StringQuality)
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    INSERT INTO #Scored (DatabaseName, DbScore, NotInspected, DbFinding)
    SELECT
        q.DatabaseName,
        CASE
            WHEN q.ErrorText IS NOT NULL THEN 1
            WHEN ISNULL(q.StringColumns, 0) = 0 THEN 3
            WHEN q.AnsiWarningsOn = 0
                 OR (ISNULL(q.CollationMismatches, 0) * 100.0 / q.StringColumns) > 5.0 THEN 1
            WHEN ISNULL(q.CollationMismatches, 0) > 0
                 OR ISNULL(q.DeprecatedTypes, 0) > 0
                 OR (ISNULL(q.MaxLengthColumns, 0) * 100.0 / q.StringColumns) > 5.0 THEN 2
            ELSE 3
        END,
        CASE WHEN q.ErrorText IS NOT NULL THEN 1 ELSE 0 END,
        LEFT(CASE
            WHEN q.ErrorText IS NOT NULL
                THEN CONCAT('[', q.DatabaseName, '] not inspectable: ', q.ErrorText)
            WHEN ISNULL(q.StringColumns, 0) = 0
                THEN CONCAT('[', q.DatabaseName, '] no user-table string columns; collation ',
                            ISNULL(q.DatabaseCollation, 'unknown'), ', ANSI_WARNINGS ',
                            CASE WHEN q.AnsiWarningsOn = 1 THEN 'ON' WHEN q.AnsiWarningsOn = 0 THEN 'OFF' ELSE 'unknown' END)
            ELSE CONCAT('[', q.DatabaseName, '] collation ', ISNULL(q.DatabaseCollation, 'unknown'),
                        ', string columns ', q.StringColumns,
                        ', collation mismatches ', ISNULL(q.CollationMismatches, 0),
                        ' (', CONVERT(DECIMAL(5, 1), ISNULL(q.CollationMismatches, 0) * 100.0 / q.StringColumns), '%)',
                        ', unbounded (n)varchar(max) columns ', ISNULL(q.MaxLengthColumns, 0),
                        ' (', CONVERT(DECIMAL(5, 1), ISNULL(q.MaxLengthColumns, 0) * 100.0 / q.StringColumns), '%)',
                        ', deprecated text/ntext columns ', ISNULL(q.DeprecatedTypes, 0),
                        ', ANSI_WARNINGS ',
                        CASE WHEN q.AnsiWarningsOn = 1 THEN 'ON (over-length writes raise an error)'
                             WHEN q.AnsiWarningsOn = 0 THEN 'OFF (string data can be silently truncated)'
                             ELSE 'unknown' END)
        END, 1000)
    FROM #StringQuality AS q;

    SELECT
        @DbCount      = COUNT(*),
        @PassCount    = SUM(CASE WHEN s.DbScore = 3 THEN 1 ELSE 0 END),
        @PartialCount = SUM(CASE WHEN s.DbScore = 2 THEN 1 ELSE 0 END),
        @FailCount    = SUM(CASE WHEN s.DbScore = 1 AND s.NotInspected = 0 THEN 1 ELSE 0 END),
        @ReviewCount  = SUM(CASE WHEN s.NotInspected = 1 THEN 1 ELSE 0 END),
        @Score        = MIN(s.DbScore)
    FROM #Scored AS s;

    SELECT @DatabaseQueried = STUFF(
        (SELECT N', ' + s.DatabaseName
         FROM #Scored AS s
         ORDER BY s.DatabaseName
         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SELECT @Detail = STUFF(
        (SELECT N' | ' + s.DbFinding
         FROM #Scored AS s
         WHERE s.DbScore < 3
         ORDER BY s.DbScore, s.DatabaseName
         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N'');

    SET @Finding = CONCAT(
        'Databases evaluated: ', ISNULL(@DbCount, 0),
        '; fully consistent: ', ISNULL(@PassCount, 0),
        '; partially compliant: ', ISNULL(@PartialCount, 0),
        '; non-compliant: ', ISNULL(@FailCount, 0),
        '; not inspectable: ', ISNULL(@ReviewCount, 0), '. ',
        ISNULL(LEFT(@Detail, 3500),
               'All evaluated databases use column collations matching the database collation, have no deprecated text/ntext columns, keep unbounded (n)varchar(max) columns at or below 5% of string columns, and run with ANSI_WARNINGS ON so over-length string writes raise an error instead of being silently truncated.'));

    SET @DatabaseQueried = ISNULL(@DatabaseQueried, 'None');
    SET @Score = ISNULL(@Score, 0);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result           AS Result,
    @Score            AS Score,
    @DatabaseQueried  AS DatabaseQueried,
    @Finding          AS Finding;

DROP TABLE #Scored;
DROP TABLE #StringQuality;