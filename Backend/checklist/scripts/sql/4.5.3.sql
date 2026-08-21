/*
    Checklist Item : 4.5.3 - Unique constraints on natural/business keys where appropriate
    Scope          : DATABASE (all accessible, online user databases)
    Read-only      : Yes - system catalog views only; temp tables used for aggregation
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
CREATE TABLE #Targets
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#DbResults') IS NOT NULL DROP TABLE #DbResults;
CREATE TABLE #DbResults
(
    DatabaseName          sysname        NOT NULL,
    UserTables            int            NULL,
    TablesWithNonPkUnique int            NULL,
    CandidateColumns      int            NULL,
    UncoveredColumns      int            NULL,
    Collected             bit            NOT NULL,
    ErrorMessage          nvarchar(2000) NULL
);

/* ---------- 1. Build the target database list ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Targets (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Targets (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4                 /* skip master, tempdb, model, msdb */
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL      /* skip database snapshots */
      AND HAS_DBACCESS(d.name) = 1;
END

/* ---------- 2. Collect metadata per database ---------- */
DECLARE @DbName   sysname,
        @Prefix   nvarchar(300),
        @Sql      nvarchar(max),
        @UT       int,
        @NPU      int,
        @CC       int,
        @UC       int,
        @ErrMsg   nvarchar(2000);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Targets ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @UT = NULL; SET @NPU = NULL; SET @CC = NULL; SET @UC = NULL; SET @ErrMsg = NULL;

    /* On Azure SQL Database only the current database is reachable, so no database prefix is used. */
    SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

    BEGIN TRY
        SET @Sql = N'
        WITH UserTables AS
        (
            SELECT t.object_id
            FROM ' + @Prefix + N'sys.tables AS t
            INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
            WHERE t.is_ms_shipped = 0
              AND t.type = ''U''
              AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
        ),
        NonPkUnique AS
        (
            SELECT DISTINCT i.object_id
            FROM ' + @Prefix + N'sys.indexes AS i
            WHERE i.is_unique = 1
              AND i.is_primary_key = 0
              AND i.is_disabled = 0
        )
        SELECT @UserTablesOut = COUNT(*),
               @NonPkUniqueOut = ISNULL(SUM(CASE WHEN EXISTS
                    (SELECT 1 FROM NonPkUnique AS n WHERE n.object_id = ut.object_id)
                    THEN 1 ELSE 0 END), 0)
        FROM UserTables AS ut;

        WITH UserTables AS
        (
            SELECT t.object_id
            FROM ' + @Prefix + N'sys.tables AS t
            INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
            WHERE t.is_ms_shipped = 0
              AND t.type = ''U''
              AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
        ),
        UniqueKeyColumns AS
        (
            SELECT DISTINCT ic.object_id, ic.column_id
            FROM ' + @Prefix + N'sys.indexes AS i
            INNER JOIN ' + @Prefix + N'sys.index_columns AS ic
                ON ic.object_id = i.object_id
               AND ic.index_id  = i.index_id
               AND ic.is_included_column = 0
            WHERE i.is_unique = 1
              AND i.is_disabled = 0
        ),
        CandidateColumns AS
        (
            SELECT c.object_id, c.column_id
            FROM ' + @Prefix + N'sys.columns AS c
            INNER JOIN UserTables AS ut ON ut.object_id = c.object_id
            WHERE c.is_identity   = 0
              AND c.is_computed   = 0
              AND c.is_rowguidcol = 0
              AND (   c.name LIKE ''%Code''
                   OR c.name LIKE ''%Number''
                   OR c.name LIKE ''%Email%''
                   OR c.name LIKE ''%SSN''
                   OR c.name LIKE ''%SKU''
                   OR c.name LIKE ''%UPC''
                   OR c.name LIKE ''%ISBN''
                   OR c.name LIKE ''%Barcode%''
                   OR c.name LIKE ''%UserName%''
                   OR c.name LIKE ''%LoginName%''
                   OR c.name LIKE ''%TaxId''
                   OR c.name LIKE ''%Slug''
                   OR c.name LIKE ''%Abbreviation''
                   OR c.name LIKE ''%ShortName'' )
        )
        SELECT @CandidateOut = COUNT(*),
               @UncoveredOut = ISNULL(SUM(CASE WHEN EXISTS
                    (SELECT 1 FROM UniqueKeyColumns AS u
                     WHERE u.object_id = cc.object_id AND u.column_id = cc.column_id)
                    THEN 0 ELSE 1 END), 0)
        FROM CandidateColumns AS cc;';

        EXEC sys.sp_executesql
             @Sql,
             N'@UserTablesOut int OUTPUT, @NonPkUniqueOut int OUTPUT, @CandidateOut int OUTPUT, @UncoveredOut int OUTPUT',
             @UserTablesOut  = @UT  OUTPUT,
             @NonPkUniqueOut = @NPU OUTPUT,
             @CandidateOut   = @CC  OUTPUT,
             @UncoveredOut   = @UC  OUTPUT;

        INSERT INTO #DbResults
            (DatabaseName, UserTables, TablesWithNonPkUnique, CandidateColumns, UncoveredColumns, Collected, ErrorMessage)
        VALUES
            (@DbName, ISNULL(@UT, 0), ISNULL(@NPU, 0), ISNULL(@CC, 0), ISNULL(@UC, 0), 1, NULL);
    END TRY
    BEGIN CATCH
        SET @ErrMsg = LEFT(ERROR_MESSAGE(), 2000);

        INSERT INTO #DbResults
            (DatabaseName, UserTables, TablesWithNonPkUnique, CandidateColumns, UncoveredColumns, Collected, ErrorMessage)
        VALUES
            (@DbName, NULL, NULL, NULL, NULL, 0, @ErrMsg);
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---------- 3. Aggregate and score ---------- */
DECLARE @DbsTargeted      int,
        @DbsCollected     int,
        @DbsSkipped       int,
        @TotalTables      int,
        @TotalNonPkUnique int,
        @TotalCandidates  int,
        @TotalUncovered   int,
        @Coverage         decimal(9,2),
        @Result           nvarchar(20),
        @Score            int,
        @DatabaseQueried  nvarchar(max),
        @WorstDbs         nvarchar(max),
        @Finding          nvarchar(max);

SELECT @DbsTargeted      = COUNT(*),
       @DbsCollected     = SUM(CASE WHEN Collected = 1 THEN 1 ELSE 0 END),
       @DbsSkipped       = SUM(CASE WHEN Collected = 0 THEN 1 ELSE 0 END),
       @TotalTables      = ISNULL(SUM(UserTables), 0),
       @TotalNonPkUnique = ISNULL(SUM(TablesWithNonPkUnique), 0),
       @TotalCandidates  = ISNULL(SUM(CandidateColumns), 0),
       @TotalUncovered   = ISNULL(SUM(UncoveredColumns), 0)
FROM #DbResults;

SET @DbsTargeted  = ISNULL(@DbsTargeted, 0);
SET @DbsCollected = ISNULL(@DbsCollected, 0);
SET @DbsSkipped   = ISNULL(@DbsSkipped, 0);

SET @DatabaseQueried =
    ISNULL(STUFF((SELECT N', ' + r.DatabaseName
                  FROM #DbResults AS r
                  WHERE r.Collected = 1
                  ORDER BY r.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

SET @WorstDbs =
    ISNULL(STUFF((SELECT TOP (5) N', ' + r.DatabaseName + N' (' + CONVERT(nvarchar(20), r.UncoveredColumns) + N')'
                  FROM #DbResults AS r
                  WHERE r.Collected = 1 AND r.UncoveredColumns > 0
                  ORDER BY r.UncoveredColumns DESC, r.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

IF @DbsCollected = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user database could be inspected (' + CONVERT(nvarchar(20), @DbsTargeted)
                 + N' targeted, ' + CONVERT(nvarchar(20), @DbsSkipped)
                 + N' inaccessible or errored). Unique-constraint coverage on natural/business keys could not be assessed automatically.';
END
ELSE IF @TotalTables = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user tables were found in the ' + CONVERT(nvarchar(20), @DbsCollected)
                 + N' inspected database(s) (' + @DatabaseQueried + N'). There is no schema to evaluate for natural/business key uniqueness.';
END
ELSE IF @TotalCandidates = 0
BEGIN
    IF @TotalNonPkUnique > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Across ' + CONVERT(nvarchar(20), @DbsCollected) + N' database(s) and '
                     + CONVERT(nvarchar(20), @TotalTables) + N' user table(s), '
                     + CONVERT(nvarchar(20), @TotalNonPkUnique)
                     + N' table(s) enforce at least one non-primary-key UNIQUE constraint or unique index, and no business-key named column was found without uniqueness enforcement.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Across ' + CONVERT(nvarchar(20), @DbsCollected) + N' database(s) and '
                     + CONVERT(nvarchar(20), @TotalTables) + N' user table(s), no non-primary-key UNIQUE constraint or unique index exists and no column matched the business-key naming patterns. Manual review against the data model is required to confirm whether natural keys exist.';
    END
END
ELSE
BEGIN
    SET @Coverage = CONVERT(decimal(9,2), 100.0 * (@TotalCandidates - @TotalUncovered) / @TotalCandidates);

    SET @Score = CASE
                    WHEN @Coverage >= 90.0 THEN 3
                    WHEN @Coverage >= 60.0 THEN 2
                    ELSE 1
                 END;

    SET @Finding = N'Across ' + CONVERT(nvarchar(20), @DbsCollected) + N' database(s) and '
                 + CONVERT(nvarchar(20), @TotalTables) + N' user table(s), '
                 + CONVERT(nvarchar(20), @TotalCandidates)
                 + N' candidate natural/business key column(s) were identified by naming pattern; '
                 + CONVERT(nvarchar(20), @TotalCandidates - @TotalUncovered) + N' are key columns of a UNIQUE constraint, unique index or primary key ('
                 + CONVERT(nvarchar(20), @Coverage) + N'% coverage) and '
                 + CONVERT(nvarchar(20), @TotalUncovered) + N' are not. '
                 + CONVERT(nvarchar(20), @TotalNonPkUnique) + N' table(s) carry at least one non-primary-key unique enforcement. Databases with the most uncovered columns: ' + @WorstDbs + N'.';
END

IF @DbsSkipped > 0 AND @DbsCollected > 0
    SET @Finding = @Finding + N' ' + CONVERT(nvarchar(20), @DbsSkipped)
                 + N' database(s) were skipped because their metadata could not be read.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

/* ---------- 4. Result ---------- */
SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbResults') IS NOT NULL DROP TABLE #DbResults;
IF OBJECT_ID('tempdb..#Targets')   IS NOT NULL DROP TABLE #Targets;