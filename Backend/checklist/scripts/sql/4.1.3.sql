/*
    Checklist Item : 4.1.3 - Data types appropriate and right-sized
                     (no oversized varchar, correct numeric precision)
    Scope          : DATABASE - every accessible user database (current database on Azure SQL Database)
    Purpose        : Read-only inventory of user-table columns that use oversized or
                     imprecise data types.
    Safety         : Reads sys.columns / sys.tables / sys.types only. No data, schema or
                     configuration is modified. Writes go to a session temp table only.
*/
SET NOCOUNT ON;

DECLARE @Result          varchar(30);
DECLARE @Score           int;
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding         nvarchar(max);

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#ColumnAudit') IS NOT NULL
    DROP TABLE #ColumnAudit;

CREATE TABLE #ColumnAudit
(
    DatabaseName       sysname NOT NULL,
    TotalColumns       int     NOT NULL,
    MaxTypeColumns     int     NOT NULL,
    OversizedVariable  int     NOT NULL,
    OversizedFixed     int     NOT NULL,
    ImpreciseNumeric   int     NOT NULL,
    ExcessivePrecision int     NOT NULL
);

DECLARE @Template nvarchar(max) = N'
INSERT INTO #ColumnAudit
    (DatabaseName, TotalColumns, MaxTypeColumns, OversizedVariable,
     OversizedFixed, ImpreciseNumeric, ExcessivePrecision)
SELECT
    @dbName,
    COUNT(*),
    ISNULL(SUM(CASE WHEN ty.name IN (''varchar'', ''nvarchar'', ''varbinary'')
                     AND c.max_length = -1 THEN 1 ELSE 0 END), 0),
    ISNULL(SUM(CASE WHEN ty.name = ''varchar''  AND c.max_length >= 1000 THEN 1
                    WHEN ty.name = ''nvarchar'' AND c.max_length >= 2000 THEN 1
                    ELSE 0 END), 0),
    ISNULL(SUM(CASE WHEN ty.name = ''char''  AND c.max_length > 50  THEN 1
                    WHEN ty.name = ''nchar'' AND c.max_length > 100 THEN 1
                    ELSE 0 END), 0),
    ISNULL(SUM(CASE WHEN ty.name IN (''float'', ''real'')
                     AND (LOWER(c.name) LIKE ''%amount%''
                       OR LOWER(c.name) LIKE ''%price%''
                       OR LOWER(c.name) LIKE ''%cost%''
                       OR LOWER(c.name) LIKE ''%salary%''
                       OR LOWER(c.name) LIKE ''%balance%''
                       OR LOWER(c.name) LIKE ''%total%''
                       OR LOWER(c.name) LIKE ''%fee%''
                       OR LOWER(c.name) LIKE ''%tax%''
                       OR LOWER(c.name) LIKE ''%currency%'') THEN 1 ELSE 0 END), 0),
    ISNULL(SUM(CASE WHEN ty.name IN (''decimal'', ''numeric'')
                     AND c.precision >= 30 THEN 1 ELSE 0 END), 0)
FROM {P}sys.columns AS c
INNER JOIN {P}sys.tables AS tb
    ON tb.object_id = c.object_id
INNER JOIN {P}sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE tb.is_ms_shipped = 0
  AND tb.type = ''U'';';

DECLARE @sql nvarchar(max);
DECLARE @db  sysname;

IF @IsAzureSqlDb = 1
BEGIN
    SET @db  = DB_NAME();
    SET @sql = REPLACE(@Template, N'{P}', N'');

    BEGIN TRY
        EXEC sp_executesql @sql, N'@dbName sysname', @dbName = @db;
    END TRY
    BEGIN CATCH
        PRINT 'Skipped database ' + @db + ': ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = REPLACE(@Template, N'{P}', QUOTENAME(@db) + N'.');

        BEGIN TRY
            EXEC sp_executesql @sql, N'@dbName sysname', @dbName = @db;
        END TRY
        BEGIN CATCH
            PRINT 'Skipped database ' + @db + ': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount            int = (SELECT COUNT(*) FROM #ColumnAudit);
DECLARE @TotalColumns       int = (SELECT ISNULL(SUM(TotalColumns), 0)       FROM #ColumnAudit);
DECLARE @MaxTypeColumns     int = (SELECT ISNULL(SUM(MaxTypeColumns), 0)     FROM #ColumnAudit);
DECLARE @OversizedVariable  int = (SELECT ISNULL(SUM(OversizedVariable), 0)  FROM #ColumnAudit);
DECLARE @OversizedFixed     int = (SELECT ISNULL(SUM(OversizedFixed), 0)     FROM #ColumnAudit);
DECLARE @ImpreciseNumeric   int = (SELECT ISNULL(SUM(ImpreciseNumeric), 0)   FROM #ColumnAudit);
DECLARE @ExcessivePrecision int = (SELECT ISNULL(SUM(ExcessivePrecision), 0) FROM #ColumnAudit);

DECLARE @Flagged    int = @MaxTypeColumns + @OversizedVariable + @OversizedFixed
                        + @ImpreciseNumeric + @ExcessivePrecision;
DECLARE @FlaggedPct decimal(5, 1) =
    CASE WHEN @TotalColumns = 0 THEN CONVERT(decimal(5, 1), 0)
         ELSE CONVERT(decimal(5, 1), 100.0 * @Flagged / @TotalColumns)
    END;

SET @DatabaseQueried =
    ISNULL(STUFF((SELECT N', ' + ca.DatabaseName
                  FROM #ColumnAudit AS ca
                  ORDER BY ca.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
           N'N/A');

DECLARE @WorstOffenders nvarchar(max) =
    ISNULL(STUFF((SELECT N'; ' + w.DatabaseName
                       + N' ' + CONVERT(varchar(20), w.Flagged)
                       + N'/' + CONVERT(varchar(20), w.TotalColumns)
                  FROM (SELECT TOP (5)
                               ca.DatabaseName,
                               ca.TotalColumns,
                               Flagged = ca.MaxTypeColumns + ca.OversizedVariable
                                       + ca.OversizedFixed + ca.ImpreciseNumeric
                                       + ca.ExcessivePrecision
                        FROM #ColumnAudit AS ca
                        WHERE ca.TotalColumns > 0
                          AND (ca.MaxTypeColumns + ca.OversizedVariable + ca.OversizedFixed
                             + ca.ImpreciseNumeric + ca.ExcessivePrecision) > 0
                        ORDER BY (1.0 * (ca.MaxTypeColumns + ca.OversizedVariable + ca.OversizedFixed
                                       + ca.ImpreciseNumeric + ca.ExcessivePrecision)
                                  / ca.TotalColumns) DESC,
                                 ca.DatabaseName) AS w
                  ORDER BY w.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
           N'none');

IF @DbCount = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'MANUAL REVIEW REQUIRED: no user database could be inspected. Either the '
                 + N'instance hosts no user databases or the audit login lacks CONNECT / '
                 + N'VIEW DEFINITION permission on them. Data type appropriateness and sizing '
                 + N'could not be measured automatically.';
END
ELSE IF @TotalColumns = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Inspected ' + CONVERT(varchar(20), @DbCount)
                 + N' user database(s); no user tables were found, so there are no '
                 + N'data type sizing issues to report.';
END
ELSE
BEGIN
    SET @Score  = CASE
                      WHEN @FlaggedPct <= 5.0  THEN 3
                      WHEN @FlaggedPct <= 15.0 THEN 2
                      WHEN @FlaggedPct <= 30.0 THEN 1
                      ELSE 0
                  END;

    SET @Finding = N'Inspected ' + CONVERT(varchar(20), @DbCount) + N' user database(s) and '
                 + CONVERT(varchar(20), @TotalColumns) + N' user-table column(s). '
                 + CONVERT(varchar(20), @Flagged) + N' column(s) ('
                 + CONVERT(varchar(10), @FlaggedPct) + N'%) use questionable data types: '
                 + N'MAX types (varchar/nvarchar/varbinary MAX) = '
                 + CONVERT(varchar(20), @MaxTypeColumns)
                 + N'; oversized variable-length strings (>= 1000 chars) = '
                 + CONVERT(varchar(20), @OversizedVariable)
                 + N'; oversized fixed-length strings (char/nchar > 50 chars) = '
                 + CONVERT(varchar(20), @OversizedFixed)
                 + N'; float/real on monetary-sounding columns = '
                 + CONVERT(varchar(20), @ImpreciseNumeric)
                 + N'; decimal/numeric with precision >= 30 = '
                 + CONVERT(varchar(20), @ExcessivePrecision)
                 + N'. Databases with the highest flagged ratio (flagged/total): '
                 + @WorstOffenders + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#ColumnAudit') IS NOT NULL
    DROP TABLE #ColumnAudit;