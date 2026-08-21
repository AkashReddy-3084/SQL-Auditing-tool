/*
    Checklist 5.2.6 - Corrupt/malformed rows isolated (not failing the entire batch)
    Scope    : DATABASE (iterates every accessible user database)
    Read-only: catalog views and DMVs only; writes go to table variables only.
*/
SET NOCOUNT ON;

DECLARE @DatabaseQueried nvarchar(4000) = N'None';
DECLARE @Finding nvarchar(4000) = N'No database found to be queried';
DECLARE @Score int = 0;
DECLARE @Result nvarchar(20) = N'Fail';

DECLARE @Results TABLE
(
    db_name          sysname NOT NULL PRIMARY KEY,
    q_objects        int NOT NULL,
    q_tables         int NOT NULL,
    q_rows           bigint NOT NULL,
    iso_modules      int NOT NULL,
    bulk_modules     int NOT NULL,
    trycatch_modules int NOT NULL,
    total_modules    int NOT NULL,
    db_score         int NOT NULL
);

DECLARE @NamePredicate nvarchar(2000) =
    N'o.name LIKE ''%error%'' OR o.name LIKE ''%reject%'' OR o.name LIKE ''%quarantin%''
      OR o.name LIKE ''%invalid%'' OR o.name LIKE ''%exception%'' OR o.name LIKE ''%deadletter%''
      OR o.name LIKE ''%dead[_]letter%'' OR o.name LIKE ''%bad[_]row%'' OR o.name LIKE ''%bad[_]record%''
      OR o.name LIKE ''%bad[_]data%'' OR o.name LIKE ''%malformed%'' OR o.name LIKE ''%failed[_]row%''
      OR o.name LIKE ''%failedrow%'' OR o.name LIKE ''%[_]err'' OR o.name LIKE ''%[_]err[_]%''';

DECLARE @Stmt nvarchar(max) =
    N'SELECT @pQObjects = COUNT(*),
             @pQTables  = ISNULL(SUM(CASE WHEN o.type = ''U'' THEN 1 ELSE 0 END), 0)
      FROM sys.objects AS o
      WHERE o.type IN (''U'', ''V'')
            AND o.is_ms_shipped = 0
            AND SCHEMA_NAME(o.schema_id) NOT IN (''sys'', ''INFORMATION_SCHEMA'')
            AND (' + @NamePredicate + N');

      SELECT @pQRows = ISNULL(SUM(ps.row_count), 0)
      FROM sys.dm_db_partition_stats AS ps
           INNER JOIN sys.objects AS o ON o.object_id = ps.object_id
      WHERE ps.index_id IN (0, 1)
            AND o.type = ''U''
            AND o.is_ms_shipped = 0
            AND SCHEMA_NAME(o.schema_id) NOT IN (''sys'', ''INFORMATION_SCHEMA'')
            AND (' + @NamePredicate + N');

      SELECT @pTotal = COUNT(*),
             @pTry = ISNULL(SUM(CASE WHEN UPPER(m.definition) LIKE ''%BEGIN TRY%''
                                          AND UPPER(m.definition) LIKE ''%BEGIN CATCH%''
                                     THEN 1 ELSE 0 END), 0),
             @pIso = ISNULL(SUM(CASE WHEN UPPER(m.definition) LIKE ''%BEGIN TRY%''
                                          AND UPPER(m.definition) LIKE ''%BEGIN CATCH%''
                                          AND (UPPER(m.definition) LIKE ''%INSERT%ERROR%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%REJECT%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%QUARANTIN%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%INVALID%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%EXCEPTION%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%BAD[_]ROW%''
                                            OR UPPER(m.definition) LIKE ''%INSERT%FAILED[_]ROW%'')
                                     THEN 1 ELSE 0 END), 0),
             @pBulk = ISNULL(SUM(CASE WHEN UPPER(m.definition) LIKE ''%MAXERRORS%''
                                           OR UPPER(m.definition) LIKE ''%ERRORFILE%''
                                           OR UPPER(m.definition) LIKE ''%REJECT[_]TYPE%''
                                           OR UPPER(m.definition) LIKE ''%REJECT[_]VALUE%''
                                           OR UPPER(m.definition) LIKE ''%REJECTED[_]ROW[_]LOCATION%''
                                      THEN 1 ELSE 0 END), 0)
      FROM sys.sql_modules AS m
           INNER JOIN sys.objects AS o ON o.object_id = m.object_id
      WHERE o.is_ms_shipped = 0
            AND o.type IN (''P'', ''TR'', ''FN'', ''TF'', ''IF'', ''V'')
            AND SCHEMA_NAME(o.schema_id) NOT IN (''sys'', ''INFORMATION_SCHEMA'');';

DECLARE @Params nvarchar(1000) =
    N'@pQObjects int OUTPUT, @pQTables int OUTPUT, @pQRows bigint OUTPUT,
      @pIso int OUTPUT, @pBulk int OUTPUT, @pTry int OUTPUT, @pTotal int OUTPUT';

DECLARE @db sysname;
DECLARE @Exec nvarchar(300);
DECLARE @qObjects int, @qTables int, @isoModules int, @bulkModules int, @tryModules int, @totalModules int;
DECLARE @qRows bigint;
DECLARE @dbScore int;

IF SERVERPROPERTY('EngineEdition') = 5      -- Azure SQL Database: cross-database queries are not available
BEGIN
    IF DB_NAME() <> N'master'
    BEGIN
        SET @qObjects = 0; SET @qTables = 0; SET @qRows = 0;
        SET @isoModules = 0; SET @bulkModules = 0; SET @tryModules = 0; SET @totalModules = 0;

        BEGIN TRY
            EXEC sys.sp_executesql @stmt = @Stmt, @params = @Params,
                 @pQObjects = @qObjects OUTPUT, @pQTables = @qTables OUTPUT, @pQRows = @qRows OUTPUT,
                 @pIso = @isoModules OUTPUT, @pBulk = @bulkModules OUTPUT,
                 @pTry = @tryModules OUTPUT, @pTotal = @totalModules OUTPUT;

            SET @dbScore = CASE
                               WHEN @qObjects > 0 AND (@isoModules > 0 OR @bulkModules > 0) THEN 3
                               WHEN @qObjects > 0 OR @isoModules > 0 OR @bulkModules > 0 THEN 2
                               WHEN @tryModules > 0 THEN 1
                               ELSE 0
                           END;

            INSERT INTO @Results (db_name, q_objects, q_tables, q_rows, iso_modules, bulk_modules, trycatch_modules, total_modules, db_score)
            VALUES (DB_NAME(), @qObjects, @qTables, @qRows, @isoModules, @bulkModules, @tryModules, @totalModules, @dbScore);
        END TRY
        BEGIN CATCH
            /* Database not readable - excluded from scoring. */
        END CATCH
    END
END
ELSE
BEGIN
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
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @qObjects = 0; SET @qTables = 0; SET @qRows = 0;
        SET @isoModules = 0; SET @bulkModules = 0; SET @tryModules = 0; SET @totalModules = 0;
        SET @Exec = QUOTENAME(@db) + N'.sys.sp_executesql';

        BEGIN TRY
            EXEC @Exec @stmt = @Stmt, @params = @Params,
                 @pQObjects = @qObjects OUTPUT, @pQTables = @qTables OUTPUT, @pQRows = @qRows OUTPUT,
                 @pIso = @isoModules OUTPUT, @pBulk = @bulkModules OUTPUT,
                 @pTry = @tryModules OUTPUT, @pTotal = @totalModules OUTPUT;

            SET @dbScore = CASE
                               WHEN @qObjects > 0 AND (@isoModules > 0 OR @bulkModules > 0) THEN 3
                               WHEN @qObjects > 0 OR @isoModules > 0 OR @bulkModules > 0 THEN 2
                               WHEN @tryModules > 0 THEN 1
                               ELSE 0
                           END;

            INSERT INTO @Results (db_name, q_objects, q_tables, q_rows, iso_modules, bulk_modules, trycatch_modules, total_modules, db_score)
            VALUES (@db, @qObjects, @qTables, @qRows, @isoModules, @bulkModules, @tryModules, @totalModules, @dbScore);
        END TRY
        BEGIN CATCH
            /* Database not readable - excluded from scoring. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

IF EXISTS (SELECT 1 FROM @Results)
BEGIN
    DECLARE @DbCount int;
    DECLARE @PassDbs int;
    DECLARE @FailDbs int;

    SELECT  @Score    = MIN(r.db_score),
            @DbCount  = COUNT(*),
            @PassDbs  = SUM(CASE WHEN r.db_score = 3 THEN 1 ELSE 0 END),
            @FailDbs  = SUM(CASE WHEN r.db_score = 0 THEN 1 ELSE 0 END)
    FROM    @Results AS r;

    SET @Result = CASE @Score WHEN 3 THEN N'Pass' WHEN 0 THEN N'Fail' ELSE N'Partial' END;

    SET @DatabaseQueried = LEFT(ISNULL(STUFF((
            SELECT N', ' + r2.db_name
            FROM   @Results AS r2
            ORDER BY r2.db_name
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None'), 4000);

    SET @Finding = LEFT(
          CASE @Score
              WHEN 3 THEN N'Row-level isolation evidenced in every database examined: quarantine/reject stores exist and ETL logic redirects failing rows. '
              WHEN 2 THEN N'Partial row-level isolation: at least one database has only half of the control, so malformed rows may still abort a batch. '
              WHEN 1 THEN N'At least one database has only batch-level TRY/CATCH error handling - no quarantine store and no row redirection, so a corrupt row can fail the entire batch. '
              ELSE N'No evidence of corrupt/malformed row isolation in at least one database: no quarantine/reject/error store and no error-handling logic found. '
          END
        + N'Databases examined: ' + CAST(@DbCount AS nvarchar(20))
        + N' (fully compliant: ' + CAST(@PassDbs AS nvarchar(20))
        + N', no evidence: ' + CAST(@FailDbs AS nvarchar(20)) + N'). Detail: '
        + ISNULL(STUFF((
              SELECT TOP (8) N'; ' + r3.db_name + N' [score ' + CAST(r3.db_score AS nvarchar(5))
                     + N'; quarantine objects=' + CAST(r3.q_objects AS nvarchar(20))
                     + N' (' + CAST(r3.q_tables AS nvarchar(20)) + N' table(s), '
                     + CAST(r3.q_rows AS nvarchar(30)) + N' isolated row(s))'
                     + N'; row-isolation modules=' + CAST(r3.iso_modules AS nvarchar(20))
                     + N'; bulk fault-tolerant modules=' + CAST(r3.bulk_modules AS nvarchar(20))
                     + N'; TRY/CATCH modules=' + CAST(r3.trycatch_modules AS nvarchar(20))
                     + N' of ' + CAST(r3.total_modules AS nvarchar(20)) + N' module(s)]'
              FROM   @Results AS r3
              ORDER BY r3.db_score, r3.db_name
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none')
        + N'.', 4000);
END

SELECT  @Result          AS Result,
        @Score           AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding         AS Finding;