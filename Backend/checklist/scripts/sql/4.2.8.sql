SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @DatabaseQueried NVARCHAR(4000);
DECLARE @Result NVARCHAR(30);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);

BEGIN TRY

    DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
    /* temporal_type only exists from SQL Server 2016 / Azure SQL Database. */
    DECLARE @HasTemporalCol BIT = CASE WHEN COL_LENGTH('sys.tables', 'temporal_type') IS NOT NULL THEN 1 ELSE 0 END;

    IF OBJECT_ID('tempdb..#Dbs')      IS NOT NULL DROP TABLE #Dbs;
    IF OBJECT_ID('tempdb..#Cols')     IS NOT NULL DROP TABLE #Cols;
    IF OBJECT_ID('tempdb..#Temporal') IS NOT NULL DROP TABLE #Temporal;
    IF OBJECT_ID('tempdb..#Scd2')     IS NOT NULL DROP TABLE #Scd2;

    CREATE TABLE #Dbs (DbName sysname NOT NULL PRIMARY KEY);

    CREATE TABLE #Cols
    (
        DbName     sysname       NOT NULL,
        ObjectId   INT           NOT NULL,
        ColumnId   INT           NOT NULL,
        SchemaName sysname       NOT NULL,
        TableName  sysname       NOT NULL,
        ColName    sysname       NOT NULL,
        NormName   NVARCHAR(256) NOT NULL,
        TypeName   sysname       NOT NULL
    );

    CREATE TABLE #Temporal (DbName sysname NOT NULL, ObjectId INT NOT NULL);

    CREATE TABLE #Scd2
    (
        DbName      sysname NOT NULL,
        ObjectId    INT     NOT NULL,
        SchemaName  sysname NOT NULL,
        TableName   sysname NOT NULL,
        FromCol     sysname NOT NULL,
        ToCol       sysname NOT NULL,
        CurrentCol  sysname NULL,
        IsTemporal  BIT     NOT NULL,
        Inspected   BIT     NOT NULL,
        BadRange    BIGINT  NULL,
        BadCurrent  BIGINT  NULL,
        BadClosed   BIGINT  NULL,
        CheckFailed BIT     NOT NULL,
        PRIMARY KEY (DbName, ObjectId)
    );

    IF @IsAzureDb = 1
    BEGIN
        INSERT INTO #Dbs (DbName)
        SELECT DB_NAME()
        WHERE  DB_NAME() NOT IN (N'master', N'tempdb');
    END
    ELSE
    BEGIN
        INSERT INTO #Dbs (DbName)
        SELECT d.name
        FROM   sys.databases AS d
        WHERE  d.database_id > 4
               AND d.state_desc = 'ONLINE'
               AND d.source_database_id IS NULL
               AND HAS_DBACCESS(d.name) = 1;
    END

    DECLARE @db sysname, @Pfx NVARCHAR(300), @sqlDb NVARCHAR(MAX);
    DECLARE @FailedDbs INT = 0;

    IF EXISTS (SELECT 1 FROM #Dbs)
    BEGIN
        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DbName FROM #Dbs ORDER BY DbName;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Pfx = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

            BEGIN TRY
                SET @sqlDb = N'INSERT INTO #Cols (DbName, ObjectId, ColumnId, SchemaName, TableName, ColName, NormName, TypeName)'
                           + N' SELECT @dbn, c.object_id, c.column_id, s.name, t.name, c.name,'
                           + N' LOWER(REPLACE(REPLACE(REPLACE(c.name, ''_'', ''''), '' '', ''''), ''-'', '''')), ty.name'
                           + N' FROM ' + @Pfx + N'sys.columns AS c'
                           + N' INNER JOIN ' + @Pfx + N'sys.tables AS t ON t.object_id = c.object_id'
                           + N' INNER JOIN ' + @Pfx + N'sys.schemas AS s ON s.schema_id = t.schema_id'
                           + N' INNER JOIN ' + @Pfx + N'sys.types AS ty ON ty.user_type_id = c.user_type_id'
                           + N' WHERE t.is_ms_shipped = 0 AND t.type = ''U'''
                           + N' AND ty.name IN (''date'',''datetime'',''datetime2'',''smalldatetime'',''datetimeoffset'','
                           + N'''bit'',''tinyint'',''smallint'',''int'',''char'',''nchar'',''varchar'',''nvarchar'');';

                EXEC sys.sp_executesql @sqlDb, N'@dbn sysname', @dbn = @db;

                IF @HasTemporalCol = 1
                BEGIN
                    SET @sqlDb = N'INSERT INTO #Temporal (DbName, ObjectId)'
                               + N' SELECT @dbn, t.object_id FROM ' + @Pfx + N'sys.tables AS t WHERE t.temporal_type = 2;';

                    EXEC sys.sp_executesql @sqlDb, N'@dbn sysname', @dbn = @db;
                END
            END TRY
            BEGIN CATCH
                SET @FailedDbs = @FailedDbs + 1;
                DELETE FROM #Dbs WHERE DbName = @db;
            END CATCH

            FETCH NEXT FROM db_cur INTO @db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    IF NOT EXISTS (SELECT 1 FROM #Dbs)
    BEGIN
        SET @DatabaseQueried = N'None';
        SET @Finding = N'No database found to be queried';
        SET @Score = 0;
    END
    ELSE
    BEGIN
        /* Derive SCD Type 2 candidates from validity-column naming conventions. */
        ;WITH fromCol AS
        (
            SELECT  c.DbName, c.ObjectId, c.SchemaName, c.TableName, c.ColName, p.Pri,
                    ROW_NUMBER() OVER (PARTITION BY c.DbName, c.ObjectId ORDER BY p.Pri, c.ColumnId) AS rn
            FROM    #Cols AS c
            CROSS APPLY (SELECT CASE c.NormName
                                     WHEN 'validfrom'          THEN 1
                                     WHEN 'validfromdate'      THEN 2
                                     WHEN 'effectivefrom'      THEN 3
                                     WHEN 'effectivefromdate'  THEN 4
                                     WHEN 'effectivestartdate' THEN 5
                                     WHEN 'validstartdate'     THEN 6
                                     WHEN 'rowstart'           THEN 7
                                     WHEN 'sysstarttime'       THEN 8
                                     WHEN 'dwvalidfrom'        THEN 9
                                     WHEN 'scdstartdate'       THEN 10
                                     WHEN 'recordstartdate'    THEN 11
                                     WHEN 'startdate'          THEN 12
                                     WHEN 'begindate'          THEN 13
                                     WHEN 'datefrom'           THEN 14
                                     WHEN 'effectivedate'      THEN 15
                                 END) AS p(Pri)
            WHERE   p.Pri IS NOT NULL
                    AND c.TypeName IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
        ),
        toCol AS
        (
            SELECT  c.DbName, c.ObjectId, c.ColName, p.Pri,
                    ROW_NUMBER() OVER (PARTITION BY c.DbName, c.ObjectId ORDER BY p.Pri, c.ColumnId) AS rn
            FROM    #Cols AS c
            CROSS APPLY (SELECT CASE c.NormName
                                     WHEN 'validto'          THEN 1
                                     WHEN 'validtodate'      THEN 2
                                     WHEN 'effectiveto'      THEN 3
                                     WHEN 'effectivetodate'  THEN 4
                                     WHEN 'effectiveenddate' THEN 5
                                     WHEN 'validenddate'     THEN 6
                                     WHEN 'rowend'           THEN 7
                                     WHEN 'sysendtime'       THEN 8
                                     WHEN 'dwvalidto'        THEN 9
                                     WHEN 'scdenddate'       THEN 10
                                     WHEN 'recordenddate'    THEN 11
                                     WHEN 'enddate'          THEN 12
                                     WHEN 'expirydate'       THEN 13
                                     WHEN 'expirationdate'   THEN 14
                                     WHEN 'dateto'           THEN 15
                                 END) AS p(Pri)
            WHERE   p.Pri IS NOT NULL
                    AND c.TypeName IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
        ),
        curCol AS
        (
            SELECT  c.DbName, c.ObjectId, c.ColName,
                    ROW_NUMBER() OVER (PARTITION BY c.DbName, c.ObjectId ORDER BY p.Pri, c.ColumnId) AS rn
            FROM    #Cols AS c
            CROSS APPLY (SELECT CASE c.NormName
                                     WHEN 'iscurrent'         THEN 1
                                     WHEN 'iscurrentflag'     THEN 2
                                     WHEN 'iscurrentrecord'   THEN 3
                                     WHEN 'iscurrentrow'      THEN 4
                                     WHEN 'currentflag'       THEN 5
                                     WHEN 'currentind'        THEN 6
                                     WHEN 'currentindicator'  THEN 7
                                     WHEN 'currentrecordflag' THEN 8
                                     WHEN 'currentrowflag'    THEN 9
                                     WHEN 'dwiscurrent'       THEN 10
                                     WHEN 'scdiscurrent'      THEN 11
                                     WHEN 'currentrecord'     THEN 12
                                     WHEN 'currentrow'        THEN 13
                                     WHEN 'islatest'          THEN 14
                                     WHEN 'islatestflag'      THEN 15
                                     WHEN 'isactiverecord'    THEN 16
                                     WHEN 'activeflag'        THEN 17
                                     WHEN 'isactive'          THEN 18
                                 END) AS p(Pri)
            WHERE   p.Pri IS NOT NULL
                    AND c.TypeName IN ('bit','tinyint','smallint','int','char','nchar','varchar','nvarchar')
        )
        INSERT INTO #Scd2 (DbName, ObjectId, SchemaName, TableName, FromCol, ToCol, CurrentCol, IsTemporal, Inspected, BadRange, BadCurrent, BadClosed, CheckFailed)
        SELECT  f.DbName,
                f.ObjectId,
                f.SchemaName,
                f.TableName,
                f.ColName,
                e.ColName,
                cc.ColName,
                CASE WHEN tp.ObjectId IS NOT NULL THEN 1 ELSE 0 END,
                0,
                NULL,
                NULL,
                NULL,
                0
        FROM    fromCol AS f
        INNER JOIN toCol AS e  ON e.DbName = f.DbName AND e.ObjectId = f.ObjectId AND e.rn = 1
        LEFT  JOIN curCol AS cc ON cc.DbName = f.DbName AND cc.ObjectId = f.ObjectId AND cc.rn = 1
        LEFT  JOIN #Temporal AS tp ON tp.DbName = f.DbName AND tp.ObjectId = f.ObjectId
        WHERE   f.rn = 1
                AND f.ColName <> e.ColName
                /* Generic start/end date pairs only qualify when a current flag is also present. */
                AND (cc.ColName IS NOT NULL OR (f.Pri <= 11 AND e.Pri <= 11));

        DECLARE @Candidates INT = (SELECT COUNT(*) FROM #Scd2);

        IF @Candidates > 0
        BEGIN
            DECLARE @MaxTables INT = 200;
            DECLARE @cdb sysname, @oid INT, @sch sysname, @tab sysname, @fc sysname, @tc sysname, @cc sysname;
            DECLARE @FullName NVARCHAR(600), @IsCurExpr NVARCHAR(MAX), @sql NVARCHAR(MAX);
            DECLARE @b1 BIGINT, @b2 BIGINT, @b3 BIGINT;

            DECLARE tbl_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT TOP (@MaxTables) DbName, ObjectId, SchemaName, TableName, FromCol, ToCol, CurrentCol
                FROM   #Scd2
                WHERE  IsTemporal = 0
                ORDER BY DbName, SchemaName, TableName;

            OPEN tbl_cur;
            FETCH NEXT FROM tbl_cur INTO @cdb, @oid, @sch, @tab, @fc, @tc, @cc;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @b1 = NULL; SET @b2 = NULL; SET @b3 = NULL;

                SET @FullName = CASE WHEN @IsAzureDb = 1
                                     THEN QUOTENAME(@sch) + N'.' + QUOTENAME(@tab)
                                     ELSE QUOTENAME(@cdb) + N'.' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tab)
                                END;

                SET @IsCurExpr = CASE
                                    WHEN @cc IS NULL THEN NULL
                                    ELSE N'UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(20), ' + QUOTENAME(@cc) + N')))) IN (N''1'', N''Y'', N''YES'', N''TRUE'', N''T'')'
                                 END;

                SET @sql = N'SELECT @p1 = SUM(CASE WHEN ' + QUOTENAME(@fc) + N' IS NOT NULL AND ' + QUOTENAME(@tc)
                         + N' IS NOT NULL AND ' + QUOTENAME(@tc) + N' < ' + QUOTENAME(@fc)
                         + N' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)';

                IF @cc IS NULL
                BEGIN
                    SET @sql = @sql + N', @p2 = NULL, @p3 = NULL';
                END
                ELSE
                BEGIN
                    SET @sql = @sql
                             + N', @p2 = SUM(CASE WHEN ' + @IsCurExpr + N' AND ' + QUOTENAME(@tc)
                             + N' IS NOT NULL AND ' + QUOTENAME(@tc) + N' < CAST(SYSDATETIME() AS date)'
                             + N' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)'
                             + N', @p3 = SUM(CASE WHEN ' + QUOTENAME(@cc) + N' IS NULL THEN CONVERT(BIGINT, 1)'
                             + N' WHEN NOT (' + @IsCurExpr + N') AND ' + QUOTENAME(@tc) + N' IS NULL THEN CONVERT(BIGINT, 1)'
                             + N' ELSE CONVERT(BIGINT, 0) END)';
                END

                SET @sql = @sql + N' FROM ' + @FullName + N';';

                BEGIN TRY
                    EXEC sys.sp_executesql @sql,
                         N'@p1 BIGINT OUTPUT, @p2 BIGINT OUTPUT, @p3 BIGINT OUTPUT',
                         @p1 = @b1 OUTPUT, @p2 = @b2 OUTPUT, @p3 = @b3 OUTPUT;

                    UPDATE #Scd2
                    SET    BadRange = @b1, BadCurrent = @b2, BadClosed = @b3, Inspected = 1
                    WHERE  DbName = @cdb AND ObjectId = @oid;
                END TRY
                BEGIN CATCH
                    UPDATE #Scd2
                    SET    CheckFailed = 1, Inspected = 1
                    WHERE  DbName = @cdb AND ObjectId = @oid;
                END CATCH

                FETCH NEXT FROM tbl_cur INTO @cdb, @oid, @sch, @tab, @fc, @tc, @cc;
            END

            CLOSE tbl_cur;
            DEALLOCATE tbl_cur;
        END

        DECLARE @DbCount     INT    = (SELECT COUNT(*) FROM #Dbs);
        DECLARE @Temporal    INT    = (SELECT COUNT(*) FROM #Scd2 WHERE IsTemporal = 1);
        DECLARE @NoFlag      INT    = (SELECT COUNT(*) FROM #Scd2 WHERE IsTemporal = 0 AND CurrentCol IS NULL);
        DECLARE @NotChecked  INT    = (SELECT COUNT(*) FROM #Scd2 WHERE IsTemporal = 0 AND Inspected = 0);
        DECLARE @Errored     INT    = (SELECT COUNT(*) FROM #Scd2 WHERE CheckFailed = 1);
        DECLARE @BadTables   INT    = (SELECT COUNT(*) FROM #Scd2
                                       WHERE ISNULL(BadRange, 0) + ISNULL(BadCurrent, 0) + ISNULL(BadClosed, 0) > 0);
        DECLARE @BadRows     BIGINT = (SELECT ISNULL(SUM(ISNULL(BadRange, 0) + ISNULL(BadCurrent, 0) + ISNULL(BadClosed, 0)), 0) FROM #Scd2);
        DECLARE @SumRange    BIGINT = (SELECT ISNULL(SUM(ISNULL(BadRange, 0)), 0)   FROM #Scd2);
        DECLARE @SumCurrent  BIGINT = (SELECT ISNULL(SUM(ISNULL(BadCurrent, 0)), 0) FROM #Scd2);
        DECLARE @SumClosed   BIGINT = (SELECT ISNULL(SUM(ISNULL(BadClosed, 0)), 0)  FROM #Scd2);

        SET @DatabaseQueried = N'';

        SELECT @DatabaseQueried = @DatabaseQueried + CASE WHEN @DatabaseQueried = N'' THEN N'' ELSE N', ' END + z.DbName
        FROM (SELECT TOP (20) DbName FROM #Dbs ORDER BY DbName) AS z;

        IF @DbCount > 20
            SET @DatabaseQueried = @DatabaseQueried + N' (+' + CAST(@DbCount - 20 AS NVARCHAR(20)) + N' more)';

        DECLARE @BadList  NVARCHAR(MAX) = N'';
        DECLARE @FlagList NVARCHAR(MAX) = N'';

        SELECT @BadList = @BadList + CASE WHEN @BadList = N'' THEN N'' ELSE N'; ' END + x.Txt
        FROM (
            SELECT TOP (5)
                   DbName + N'.' + SchemaName + N'.' + TableName
                 + N' (endBeforeStart=' + CAST(ISNULL(BadRange, 0) AS NVARCHAR(20))
                 + N', currentButExpired=' + CAST(ISNULL(BadCurrent, 0) AS NVARCHAR(20))
                 + N', missingEndDate=' + CAST(ISNULL(BadClosed, 0) AS NVARCHAR(20)) + N')' AS Txt,
                   ISNULL(BadRange, 0) + ISNULL(BadCurrent, 0) + ISNULL(BadClosed, 0) AS BadTotal
            FROM   #Scd2
            WHERE  ISNULL(BadRange, 0) + ISNULL(BadCurrent, 0) + ISNULL(BadClosed, 0) > 0
            ORDER BY BadTotal DESC
        ) AS x;

        SELECT @FlagList = @FlagList + CASE WHEN @FlagList = N'' THEN N'' ELSE N', ' END + y.Txt
        FROM (
            SELECT TOP (5) DbName + N'.' + SchemaName + N'.' + TableName AS Txt
            FROM   #Scd2
            WHERE  IsTemporal = 0 AND CurrentCol IS NULL
            ORDER BY DbName, SchemaName, TableName
        ) AS y;

        IF @Candidates = 0
        BEGIN
            SET @Score = 3;
            SET @Finding = N'No SCD Type 2 structures were detected across the ' + CAST(@DbCount AS NVARCHAR(20))
                         + N' user database(s) queried: no user table exposes a recognised valid_from/valid_to (or effective-from/effective-to, row start/end) date pair, with or without an is_current style flag. The control is scoped "where used", so it is not applicable here.';
        END
        ELSE IF @BadTables = 0 AND @NoFlag = 0 AND @Errored = 0 AND @NotChecked = 0
        BEGIN
            SET @Score = 3;
            SET @Finding = N'All ' + CAST(@Candidates AS NVARCHAR(20)) + N' SCD Type 2 table(s) found across '
                         + CAST(@DbCount AS NVARCHAR(20)) + N' user database(s) carry valid_from, valid_to and an is_current style flag (system-versioned temporal tables included: '
                         + CAST(@Temporal AS NVARCHAR(20)) + N'), and no row-level validity defects were found: 0 rows with end date before start date, 0 rows flagged current while already expired, and 0 closed or NULL-flag rows without an end date.';
        END
        ELSE IF @BadTables = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = N'Row-level validity data is clean across the ' + CAST(@Candidates AS NVARCHAR(20))
                         + N' SCD Type 2 table(s) found, but the pattern is incompletely implemented: '
                         + CAST(@NoFlag AS NVARCHAR(20)) + N' table(s) have valid_from/valid_to without any is_current flag'
                         + CASE WHEN @FlagList = N'' THEN N'' ELSE N' (e.g. ' + @FlagList + N')' END
                         + N'; ' + CAST(@Errored AS NVARCHAR(20)) + N' table(s) could not be read and '
                         + CAST(@NotChecked AS NVARCHAR(20)) + N' table(s) were beyond the 200-table inspection cap.';
        END
        ELSE IF @BadTables * 2 <= @Candidates
        BEGIN
            SET @Score = 1;
            SET @Finding = CAST(@BadTables AS NVARCHAR(20)) + N' of ' + CAST(@Candidates AS NVARCHAR(20))
                         + N' SCD Type 2 table(s) are not maintained correctly, affecting '
                         + CAST(@BadRows AS NVARCHAR(20)) + N' row(s): ' + CAST(@SumRange AS NVARCHAR(20))
                         + N' row(s) with valid_to earlier than valid_from, ' + CAST(@SumCurrent AS NVARCHAR(20))
                         + N' row(s) flagged current although valid_to has already passed, and ' + CAST(@SumClosed AS NVARCHAR(20))
                         + N' row(s) with a NULL or non-current flag but no valid_to. Worst offenders: ' + @BadList
                         + N'. Additionally ' + CAST(@NoFlag AS NVARCHAR(20)) + N' table(s) have no is_current flag.';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = N'SCD Type 2 maintenance is broadly unreliable: ' + CAST(@BadTables AS NVARCHAR(20))
                         + N' of ' + CAST(@Candidates AS NVARCHAR(20)) + N' table(s) contain validity defects across '
                         + CAST(@BadRows AS NVARCHAR(20)) + N' row(s) (' + CAST(@SumRange AS NVARCHAR(20))
                         + N' end-before-start, ' + CAST(@SumCurrent AS NVARCHAR(20)) + N' current-but-expired, '
                         + CAST(@SumClosed AS NVARCHAR(20)) + N' closed-without-end-date). Worst offenders: ' + @BadList
                         + N'. Additionally ' + CAST(@NoFlag AS NVARCHAR(20)) + N' table(s) have no is_current flag.';
        END

        IF @FailedDbs > 0
            SET @Finding = @Finding + N' Note: ' + CAST(@FailedDbs AS NVARCHAR(20)) + N' database(s) were skipped because their catalog could not be read.';
    END

END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'tbl_cur') > -1 CLOSE tbl_cur;
    IF CURSOR_STATUS('local', 'tbl_cur') > -3 DEALLOCATE tbl_cur;
    IF CURSOR_STATUS('local', 'db_cur') > -1 CLOSE db_cur;
    IF CURSOR_STATUS('local', 'db_cur') > -3 DEALLOCATE db_cur;

    SET @Score = 0;
    SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'None');
    SET @Finding = N'SCD Type 2 validity check could not be completed. Error '
                 + CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': ' + ERROR_MESSAGE();
END CATCH

IF OBJECT_ID('tempdb..#Dbs')      IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Cols')     IS NOT NULL DROP TABLE #Cols;
IF OBJECT_ID('tempdb..#Temporal') IS NOT NULL DROP TABLE #Temporal;
IF OBJECT_ID('tempdb..#Scd2')     IS NOT NULL DROP TABLE #Scd2;

IF @DatabaseQueried IS NULL OR LTRIM(RTRIM(@DatabaseQueried)) = N''
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT  @Result           AS Result,
        @Score            AS Score,
        @DatabaseQueried  AS DatabaseQueried,
        @Finding          AS Finding;