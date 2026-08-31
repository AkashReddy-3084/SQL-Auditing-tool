SET NOCOUNT ON;

DECLARE @LongTxMinutes     INT = 5;
DECLARE @CriticalTxMinutes INT = 30;
DECLARE @IsAzureSqlDb      BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @CollectionError   NVARCHAR(2000) = NULL;

DECLARE @LongTx TABLE (
    SessionId       INT           NULL,
    DatabaseName    NVARCHAR(256) NULL,
    DurationMinutes INT           NULL,
    LogBytesUsed    BIGINT        NULL,
    SessionStatus   NVARCHAR(60)  NULL
);

DECLARE @Modules TABLE (
    DatabaseName NVARCHAR(256) NULL,
    ObjectName   NVARCHAR(512) NULL
);

DECLARE @ScannedDbs TABLE (DatabaseName NVARCHAR(256) NOT NULL);

/* Signal A: user transactions that are currently open beyond the long-running threshold. */
BEGIN TRY
    INSERT INTO @LongTx (SessionId, DatabaseName, DurationMinutes, LogBytesUsed, SessionStatus)
    SELECT
        tst.session_id,
        MAX(COALESCE(DB_NAME(tdt.database_id), N'(unknown)')),
        MAX(DATEDIFF(MINUTE, tat.transaction_begin_time, GETDATE())),
        SUM(COALESCE(tdt.database_transaction_log_bytes_used, CONVERT(BIGINT, 0))),
        MAX(COALESCE(es.status, N'unknown'))
    FROM sys.dm_tran_active_transactions AS tat
    INNER JOIN sys.dm_tran_session_transactions AS tst
        ON tst.transaction_id = tat.transaction_id
    INNER JOIN sys.dm_exec_sessions AS es
        ON es.session_id = tst.session_id
    LEFT JOIN sys.dm_tran_database_transactions AS tdt
        ON tdt.transaction_id = tat.transaction_id
    WHERE tst.is_user_transaction = 1
      AND es.is_user_process = 1
      AND tat.transaction_begin_time IS NOT NULL
      AND tat.transaction_begin_time < DATEADD(MINUTE, -@LongTxMinutes, GETDATE())
    GROUP BY tst.session_id;
END TRY
BEGIN CATCH
    SET @CollectionError = N'Active transaction DMV read failed: ' + ERROR_MESSAGE();
END CATCH

/* Signal B: module code that opens an explicit transaction around bulk DML with no batching construct. */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO @ScannedDbs (DatabaseName) VALUES (DB_NAME());

    BEGIN TRY
        INSERT INTO @Modules (DatabaseName, ObjectName)
        SELECT
            DB_NAME(),
            QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
        FROM sys.sql_modules AS sm
        INNER JOIN sys.objects AS o ON o.object_id = sm.object_id
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND sm.definition LIKE N'%BEGIN TRAN%'
          AND (    sm.definition LIKE N'%DELETE %'
                OR sm.definition LIKE N'%UPDATE %'
                OR sm.definition LIKE N'%MERGE %'
                OR sm.definition LIKE N'%INSERT INTO%')
          AND sm.definition NOT LIKE N'%WHILE%'
          AND sm.definition NOT LIKE N'%TOP %'
          AND sm.definition NOT LIKE N'%TOP(%'
          AND sm.definition NOT LIKE N'%ROWCOUNT%';
    END TRY
    BEGIN CATCH
        SET @CollectionError = ISNULL(@CollectionError + N' | ', N'') + N'Module scan failed for current database: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql    NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO @ScannedDbs (DatabaseName) VALUES (@DbName);

            SET @Sql =
                N'SELECT @db, QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) ' + NCHAR(13) + NCHAR(10) +
                N'FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS sm ' + NCHAR(13) + NCHAR(10) +
                N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o ON o.object_id = sm.object_id ' + NCHAR(13) + NCHAR(10) +
                N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = o.schema_id ' + NCHAR(13) + NCHAR(10) +
                N'WHERE o.is_ms_shipped = 0 ' + NCHAR(13) + NCHAR(10) +
                N'  AND sm.definition LIKE N''%BEGIN TRAN%'' ' + NCHAR(13) + NCHAR(10) +
                N'  AND (sm.definition LIKE N''%DELETE %'' OR sm.definition LIKE N''%UPDATE %'' OR sm.definition LIKE N''%MERGE %'' OR sm.definition LIKE N''%INSERT INTO%'') ' + NCHAR(13) + NCHAR(10) +
                N'  AND sm.definition NOT LIKE N''%WHILE%'' ' + NCHAR(13) + NCHAR(10) +
                N'  AND sm.definition NOT LIKE N''%TOP %'' ' + NCHAR(13) + NCHAR(10) +
                N'  AND sm.definition NOT LIKE N''%TOP(%'' ' + NCHAR(13) + NCHAR(10) +
                N'  AND sm.definition NOT LIKE N''%ROWCOUNT%'';';

            INSERT INTO @Modules (DatabaseName, ObjectName)
            EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
        END TRY
        BEGIN CATCH
            SET @CollectionError = ISNULL(@CollectionError + N' | ', N'') + N'Module scan failed for [' + @DbName + N']: ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @LongCount     INT = (SELECT COUNT(*) FROM @LongTx);
DECLARE @CriticalCount INT = (SELECT COUNT(*) FROM @LongTx WHERE DurationMinutes >= @CriticalTxMinutes);
DECLARE @MaxMinutes    INT = (SELECT ISNULL(MAX(DurationMinutes), 0) FROM @LongTx);
DECLARE @ModuleCount   INT = (SELECT COUNT(*) FROM @Modules);
DECLARE @DbCount       INT = (SELECT COUNT(*) FROM @ScannedDbs);

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM @ScannedDbs
           ORDER BY DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score   INT;
DECLARE @Result  NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

IF @CriticalCount > 0 OR @ModuleCount > 5
    SET @Score = 1;
ELSE IF @LongCount > 0 OR @ModuleCount > 0
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Databases scanned: ' + CAST(@DbCount AS NVARCHAR(10))
    + N'. User transactions currently open longer than ' + CAST(@LongTxMinutes AS NVARCHAR(10)) + N' minutes: ' + CAST(@LongCount AS NVARCHAR(10))
    + N' (open ' + CAST(@CriticalTxMinutes AS NVARCHAR(10)) + N' minutes or more: ' + CAST(@CriticalCount AS NVARCHAR(10))
    + N'; longest open transaction: ' + CAST(@MaxMinutes AS NVARCHAR(10)) + N' minutes). '
    + N'User modules opening an explicit transaction around bulk DML with no batching construct (WHILE / TOP / ROWCOUNT): '
    + CAST(@ModuleCount AS NVARCHAR(10)) + N'. ';

IF @LongCount > 0
    SET @Finding = @Finding + N'Longest open transactions: '
        + ISNULL(STUFF((SELECT TOP (5)
                            N'; session ' + CAST(SessionId AS NVARCHAR(10))
                          + N' on [' + DatabaseName + N'] open ' + CAST(DurationMinutes AS NVARCHAR(10)) + N' min, log used '
                          + CAST(LogBytesUsed / 1024 AS NVARCHAR(20)) + N' KB, status ' + SessionStatus
                        FROM @LongTx
                        ORDER BY DurationMinutes DESC
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none') + N'. ';

IF @ModuleCount > 0
    SET @Finding = @Finding + N'Un-batched bulk-DML modules (first 10): '
        + ISNULL(STUFF((SELECT TOP (10)
                            N'; [' + DatabaseName + N'].' + ObjectName
                        FROM @Modules
                        ORDER BY DatabaseName, ObjectName
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none') + N'. ';

IF @Score = 3
    SET @Finding = @Finding + N'No long-running open transaction and no un-batched bulk-DML module were detected. ';

SET @Finding = @Finding
    + N'Note: the transaction check is a point-in-time observation of currently open transactions.';

IF @CollectionError IS NOT NULL
    SET @Finding = @Finding + N' Collection warnings: ' + @CollectionError;

SELECT
    @Result                     AS Result,
    @Score                      AS Score,
    ISNULL(@DbList, DB_NAME())  AS DatabaseQueried,
    @Finding                    AS Finding;