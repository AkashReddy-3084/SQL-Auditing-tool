SET NOCOUNT ON;

DECLARE @DbStats TABLE
(
    DatabaseName      SYSNAME,
    TotalTables       INT,
    TablesWithCheck   INT,
    CheckConstraints  INT,
    UntrustedChecks   INT,
    DisabledChecks    INT
);

DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @sql NVARCHAR(MAX);
DECLARE @db  SYSNAME;

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO @DbStats (DatabaseName, TotalTables, TablesWithCheck, CheckConstraints, UntrustedChecks, DisabledChecks)
    SELECT
        DB_NAME(),
        (SELECT COUNT(*)
           FROM sys.tables t
           JOIN sys.schemas s ON s.schema_id = t.schema_id
          WHERE t.is_ms_shipped = 0
            AND t.type = 'U'
            AND s.name NOT IN ('sys')),
        (SELECT COUNT(DISTINCT cc.parent_object_id)
           FROM sys.check_constraints cc
           JOIN sys.tables t ON t.object_id = cc.parent_object_id
          WHERE t.is_ms_shipped = 0),
        (SELECT COUNT(*)
           FROM sys.check_constraints cc
           JOIN sys.tables t ON t.object_id = cc.parent_object_id
          WHERE t.is_ms_shipped = 0),
        (SELECT COUNT(*)
           FROM sys.check_constraints cc
           JOIN sys.tables t ON t.object_id = cc.parent_object_id
          WHERE t.is_ms_shipped = 0 AND cc.is_not_trusted = 1),
        (SELECT COUNT(*)
           FROM sys.check_constraints cc
           JOIN sys.tables t ON t.object_id = cc.parent_object_id
          WHERE t.is_ms_shipped = 0 AND cc.is_disabled = 1);
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases d
         WHERE d.database_id > 4
           AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution', 'SSISDB', 'ReportServer', 'ReportServerTempDB')
           AND d.state_desc = 'ONLINE'
           AND d.is_read_only = 0
           AND d.source_database_id IS NULL
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
        SELECT
            @dbname,
            (SELECT COUNT(*)
               FROM ' + QUOTENAME(@db) + N'.sys.tables t
               JOIN ' + QUOTENAME(@db) + N'.sys.schemas s ON s.schema_id = t.schema_id
              WHERE t.is_ms_shipped = 0
                AND t.type = ''U''
                AND s.name NOT IN (''sys'')),
            (SELECT COUNT(DISTINCT cc.parent_object_id)
               FROM ' + QUOTENAME(@db) + N'.sys.check_constraints cc
               JOIN ' + QUOTENAME(@db) + N'.sys.tables t ON t.object_id = cc.parent_object_id
              WHERE t.is_ms_shipped = 0),
            (SELECT COUNT(*)
               FROM ' + QUOTENAME(@db) + N'.sys.check_constraints cc
               JOIN ' + QUOTENAME(@db) + N'.sys.tables t ON t.object_id = cc.parent_object_id
              WHERE t.is_ms_shipped = 0),
            (SELECT COUNT(*)
               FROM ' + QUOTENAME(@db) + N'.sys.check_constraints cc
               JOIN ' + QUOTENAME(@db) + N'.sys.tables t ON t.object_id = cc.parent_object_id
              WHERE t.is_ms_shipped = 0 AND cc.is_not_trusted = 1),
            (SELECT COUNT(*)
               FROM ' + QUOTENAME(@db) + N'.sys.check_constraints cc
               JOIN ' + QUOTENAME(@db) + N'.sys.tables t ON t.object_id = cc.parent_object_id
              WHERE t.is_ms_shipped = 0 AND cc.is_disabled = 1);';

        BEGIN TRY
            INSERT INTO @DbStats (DatabaseName, TotalTables, TablesWithCheck, CheckConstraints, UntrustedChecks, DisabledChecks)
            EXEC sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
        END TRY
        BEGIN CATCH
            -- database became inaccessible mid-scan; skip it
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount          INT = (SELECT COUNT(*) FROM @DbStats);
DECLARE @TotalTables      INT = (SELECT ISNULL(SUM(TotalTables), 0) FROM @DbStats);
DECLARE @TablesWithCheck  INT = (SELECT ISNULL(SUM(TablesWithCheck), 0) FROM @DbStats);
DECLARE @TotalChecks      INT = (SELECT ISNULL(SUM(CheckConstraints), 0) FROM @DbStats);
DECLARE @Untrusted        INT = (SELECT ISNULL(SUM(UntrustedChecks), 0) FROM @DbStats);
DECLARE @Disabled         INT = (SELECT ISNULL(SUM(DisabledChecks), 0) FROM @DbStats);

DECLARE @Coverage DECIMAL(6,2) =
    CASE WHEN @TotalTables > 0
         THEN CAST(@TablesWithCheck * 100.0 / @TotalTables AS DECIMAL(6,2))
         ELSE 0 END;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + s.DatabaseName
             FROM @DbStats s
            ORDER BY s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @NoCheckDbs NVARCHAR(MAX) =
    STUFF((SELECT N', ' + s.DatabaseName
             FROM @DbStats s
            WHERE s.TotalTables > 0 AND s.CheckConstraints = 0
            ORDER BY s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result   NVARCHAR(20);
DECLARE @Score    INT;
DECLARE @Finding  NVARCHAR(MAX);

IF @DbCount = 0 OR @TotalTables = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible user database with user tables was found, so CHECK constraint coverage could not be measured. Databases inspected: '
                 + ISNULL(@DbList, N'None') + N'. Manual review required.';
END
ELSE IF @Coverage >= 50.0 AND @Untrusted = 0 AND @Disabled = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'CHECK constraints enforce domain rules broadly: '
                 + CAST(@TablesWithCheck AS NVARCHAR(20)) + N' of ' + CAST(@TotalTables AS NVARCHAR(20))
                 + N' user tables (' + CAST(@Coverage AS NVARCHAR(20)) + N'%) across ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' database(s) carry at least one CHECK constraint. Total CHECK constraints: ' + CAST(@TotalChecks AS NVARCHAR(20))
                 + N'. No disabled and no untrusted CHECK constraints were found.';
END
ELSE IF @Coverage >= 50.0
BEGIN
    SET @Score = 2;
    SET @Finding = N'CHECK constraint coverage is adequate (' + CAST(@TablesWithCheck AS NVARCHAR(20)) + N' of '
                 + CAST(@TotalTables AS NVARCHAR(20)) + N' user tables, ' + CAST(@Coverage AS NVARCHAR(20))
                 + N'%) but enforcement is weakened: ' + CAST(@Disabled AS NVARCHAR(20)) + N' disabled and '
                 + CAST(@Untrusted AS NVARCHAR(20)) + N' untrusted (NOCHECK) CHECK constraint(s) out of '
                 + CAST(@TotalChecks AS NVARCHAR(20)) + N' total across ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s).';
END
ELSE IF @Coverage >= 25.0
BEGIN
    SET @Score = 2;
    SET @Finding = N'CHECK constraint coverage is partial: only ' + CAST(@TablesWithCheck AS NVARCHAR(20)) + N' of '
                 + CAST(@TotalTables AS NVARCHAR(20)) + N' user tables (' + CAST(@Coverage AS NVARCHAR(20))
                 + N'%) across ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) have a CHECK constraint. Total CHECK constraints: '
                 + CAST(@TotalChecks AS NVARCHAR(20)) + N' (' + CAST(@Disabled AS NVARCHAR(20)) + N' disabled, '
                 + CAST(@Untrusted AS NVARCHAR(20)) + N' untrusted). Databases with no CHECK constraints at all: '
                 + ISNULL(@NoCheckDbs, N'None') + N'.';
END
ELSE IF @TotalChecks > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'CHECK constraints are almost absent: only ' + CAST(@TablesWithCheck AS NVARCHAR(20)) + N' of '
                 + CAST(@TotalTables AS NVARCHAR(20)) + N' user tables (' + CAST(@Coverage AS NVARCHAR(20))
                 + N'%) across ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) have any CHECK constraint. Total CHECK constraints: '
                 + CAST(@TotalChecks AS NVARCHAR(20)) + N' (' + CAST(@Disabled AS NVARCHAR(20)) + N' disabled, '
                 + CAST(@Untrusted AS NVARCHAR(20)) + N' untrusted). Databases with no CHECK constraints at all: '
                 + ISNULL(@NoCheckDbs, N'None') + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'No CHECK constraints exist on any of the ' + CAST(@TotalTables AS NVARCHAR(20))
                 + N' user tables across ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' database(s); domain rules are not enforced by the database engine. Databases with no CHECK constraints: '
                 + ISNULL(@NoCheckDbs, N'None') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                        AS Result,
    @Score                         AS Score,
    ISNULL(@DbList, N'None')       AS DatabaseQueried,
    @Finding                       AS Finding;