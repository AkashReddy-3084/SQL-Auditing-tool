SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#ScannedDbs') IS NOT NULL DROP TABLE #ScannedDbs;

CREATE TABLE #Modules
(
    DatabaseName  sysname        NOT NULL,
    ObjectName    nvarchar(776)  NOT NULL,
    HasTry        bit            NOT NULL,
    HasCatch      bit            NOT NULL,
    HasErrorRaise bit            NOT NULL,
    HasDml        bit            NOT NULL
);

CREATE TABLE #ScannedDbs (DatabaseName sysname NOT NULL);

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Skipped nvarchar(max) = N'';

DECLARE @Body nvarchar(max) = N'
SELECT DB_NAME(),
       QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name),
       CASE WHEN CHARINDEX(N''BEGIN TRY'', UPPER(m.definition)) > 0 THEN 1 ELSE 0 END,
       CASE WHEN CHARINDEX(N''BEGIN CATCH'', UPPER(m.definition)) > 0 THEN 1 ELSE 0 END,
       CASE WHEN CHARINDEX(N''BEGIN CATCH'', UPPER(m.definition)) > 0
                 AND (CHARINDEX(N''THROW'', UPPER(m.definition), CHARINDEX(N''BEGIN CATCH'', UPPER(m.definition))) > 0
                      OR CHARINDEX(N''RAISERROR'', UPPER(m.definition), CHARINDEX(N''BEGIN CATCH'', UPPER(m.definition))) > 0)
            THEN 1 ELSE 0 END,
       CASE WHEN UPPER(m.definition) LIKE N''%INSERT%''
                 OR UPPER(m.definition) LIKE N''%UPDATE%''
                 OR UPPER(m.definition) LIKE N''%DELETE%''
                 OR UPPER(m.definition) LIKE N''%MERGE%''
            THEN 1 ELSE 0 END
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o ON o.object_id = m.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''TR'');';

IF @IsAzureSqlDb = 1
BEGIN
    IF DB_ID() > 4
    BEGIN
        INSERT INTO #ScannedDbs (DatabaseName) VALUES (DB_NAME());

        BEGIN TRY
            INSERT INTO #Modules (DatabaseName, ObjectName, HasTry, HasCatch, HasErrorRaise, HasDml)
            EXEC sys.sp_executesql @Body;
        END TRY
        BEGIN CATCH
            SET @Skipped = @Skipped + DB_NAME() + N'; ';
        END CATCH
    END
END
ELSE
BEGIN
    DECLARE @db sysname;
    DECLARE @sql nvarchar(max);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO #ScannedDbs (DatabaseName) VALUES (@db);

        SET @sql = N'USE ' + QUOTENAME(@db) + N';' + @Body;

        BEGIN TRY
            INSERT INTO #Modules (DatabaseName, ObjectName, HasTry, HasCatch, HasErrorRaise, HasDml)
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @Skipped = @Skipped + @db + N'; ';
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount int = (SELECT COUNT(*) FROM #ScannedDbs);

DECLARE @Score           int;
DECLARE @Result          nvarchar(20);
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding         nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    DECLARE @Total          int = 0,
            @DmlModules     int = 0,
            @DmlWithTry     int = 0,
            @WithCatch      int = 0,
            @CatchWithRaise int = 0;

    SELECT @Total          = COUNT(*),
           @DmlModules     = ISNULL(SUM(CASE WHEN HasDml = 1 THEN 1 ELSE 0 END), 0),
           @DmlWithTry     = ISNULL(SUM(CASE WHEN HasDml = 1 AND HasTry = 1 AND HasCatch = 1 THEN 1 ELSE 0 END), 0),
           @WithCatch      = ISNULL(SUM(CASE WHEN HasCatch = 1 THEN 1 ELSE 0 END), 0),
           @CatchWithRaise = ISNULL(SUM(CASE WHEN HasCatch = 1 AND HasErrorRaise = 1 THEN 1 ELSE 0 END), 0)
    FROM #Modules;

    DECLARE @TryPct   decimal(5, 2) = CASE WHEN @DmlModules > 0 THEN (100.0 * @DmlWithTry) / @DmlModules END;
    DECLARE @RaisePct decimal(5, 2) = CASE WHEN @WithCatch  > 0 THEN (100.0 * @CatchWithRaise) / @WithCatch END;

    SET @DatabaseQueried =
        STUFF((SELECT N', ' + d.DatabaseName
               FROM (SELECT DISTINCT DatabaseName FROM #ScannedDbs) AS d
               ORDER BY d.DatabaseName
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    DECLARE @Offenders nvarchar(max) =
        STUFF((SELECT TOP (10) N'; ' + m.DatabaseName + N'.' + m.ObjectName
               FROM #Modules AS m
               WHERE m.HasCatch = 1 AND m.HasErrorRaise = 0
               ORDER BY m.DatabaseName, m.ObjectName
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    DECLARE @NoTry nvarchar(max) =
        STUFF((SELECT TOP (10) N'; ' + m.DatabaseName + N'.' + m.ObjectName
               FROM #Modules AS m
               WHERE m.HasDml = 1 AND (m.HasTry = 0 OR m.HasCatch = 0)
               ORDER BY m.DatabaseName, m.ObjectName
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @Total = 0
        SET @Score = 3;
    ELSE IF @WithCatch = 0
        SET @Score = 0;
    ELSE IF (@DmlModules = 0 OR @TryPct >= 80.0) AND @RaisePct >= 90.0
        SET @Score = 3;
    ELSE IF (@DmlModules = 0 OR @TryPct >= 50.0) AND @RaisePct >= 70.0
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    IF @Total = 0
        SET @Finding = N'No user-defined stored procedures or triggers were found in the scanned databases, so there is no T-SQL error-handling surface to assess. Databases scanned: ' + @DatabaseQueried + N'.';
    ELSE
        SET @Finding =
            N'Scanned ' + CONVERT(nvarchar(20), @Total) + N' user stored procedures/triggers. '
          + CONVERT(nvarchar(20), @DmlModules) + N' perform DML, of which '
          + CONVERT(nvarchar(20), @DmlWithTry) + N' ('
          + ISNULL(CONVERT(nvarchar(20), @TryPct), N'n/a') + N'%) contain a TRY...CATCH block. '
          + CONVERT(nvarchar(20), @WithCatch) + N' modules contain a CATCH block and '
          + CONVERT(nvarchar(20), @CatchWithRaise) + N' ('
          + ISNULL(CONVERT(nvarchar(20), @RaisePct), N'n/a') + N'%) re-raise or log the error with THROW/RAISERROR; '
          + CONVERT(nvarchar(20), @WithCatch - @CatchWithRaise) + N' swallow the error silently.'
          + CASE WHEN @Offenders IS NOT NULL THEN N' CATCH without THROW/RAISERROR (up to 10): ' + @Offenders + N'.' ELSE N'' END
          + CASE WHEN @NoTry IS NOT NULL THEN N' DML modules without TRY...CATCH (up to 10): ' + @NoTry + N'.' ELSE N'' END
          + CASE WHEN LEN(@Skipped) > 0 THEN N' Databases skipped due to access errors: ' + @Skipped ELSE N'' END;
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                   WHEN @Score = 0 THEN N'Fail'
                   ELSE N'Partial' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Modules') IS NOT NULL DROP TABLE #Modules;
IF OBJECT_ID('tempdb..#ScannedDbs') IS NOT NULL DROP TABLE #ScannedDbs;