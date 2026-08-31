SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#FkAudit') IS NOT NULL DROP TABLE #FkAudit;
CREATE TABLE #FkAudit (
    DatabaseName sysname NOT NULL,
    ForeignKeyName sysname NULL,
    ParentSchema sysname NULL,
    ParentTable sysname NULL,
    ReferencedSchema sysname NULL,
    ReferencedTable sysname NULL,
    IsDisabled bit NULL,
    IsNotTrusted bit NULL,
    IsNotForReplication bit NULL,
    UserTableCount int NOT NULL DEFAULT 0,
    FkCount int NOT NULL DEFAULT 0,
    RowType varchar(20) NOT NULL
);

DECLARE @sql nvarchar(max);
DECLARE @db sysname;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT d.name
FROM sys.databases d
WHERE d.state = 0
  AND d.is_read_only = 0
  AND d.database_id > 4
  AND HAS_DBACCESS(d.name) = 1
  AND d.name NOT IN ('distribution', 'SSISDB');

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
USE ' + QUOTENAME(@db) + N';

DECLARE @userTables int = (
    SELECT COUNT(*)
    FROM sys.tables t
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND t.temporal_type IN (0, 2)
);

DECLARE @fkCount int = (
    SELECT COUNT(*)
    FROM sys.foreign_keys fk
    INNER JOIN sys.tables t ON t.object_id = fk.parent_object_id
    WHERE t.is_ms_shipped = 0
);

INSERT INTO #FkAudit (DatabaseName, UserTableCount, FkCount, RowType)
SELECT DB_NAME(), @userTables, @fkCount, ''SUMMARY'';

INSERT INTO #FkAudit (
    DatabaseName, ForeignKeyName, ParentSchema, ParentTable,
    ReferencedSchema, ReferencedTable, IsDisabled, IsNotTrusted,
    IsNotForReplication, UserTableCount, FkCount, RowType
)
SELECT
    DB_NAME(),
    fk.name,
    ps.name,
    pt.name,
    rs.name,
    rt.name,
    fk.is_disabled,
    fk.is_not_trusted,
    fk.is_not_for_replication,
    @userTables,
    @fkCount,
    ''FK''
FROM sys.foreign_keys fk
INNER JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
INNER JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
INNER JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
INNER JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
WHERE pt.is_ms_shipped = 0
  AND (fk.is_disabled = 1 OR fk.is_not_trusted = 1);
';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #FkAudit (DatabaseName, UserTableCount, FkCount, RowType)
        VALUES (@db, 0, 0, 'ERROR');
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @dbCount int = (SELECT COUNT(DISTINCT DatabaseName) FROM #FkAudit WHERE RowType IN ('SUMMARY','FK','ERROR'));
DECLARE @errCount int = (SELECT COUNT(*) FROM #FkAudit WHERE RowType = 'ERROR');
DECLARE @totalUserTables int = (SELECT ISNULL(SUM(UserTableCount),0) FROM #FkAudit WHERE RowType = 'SUMMARY');
DECLARE @totalFks int = (SELECT ISNULL(SUM(FkCount),0) FROM #FkAudit WHERE RowType = 'SUMMARY');
DECLARE @disabledCount int = (SELECT COUNT(*) FROM #FkAudit WHERE RowType = 'FK' AND IsDisabled = 1);
DECLARE @untrustedCount int = (SELECT COUNT(*) FROM #FkAudit WHERE RowType = 'FK' AND IsNotTrusted = 1 AND IsDisabled = 0);
DECLARE @dbsWithTablesNoFk int = (
    SELECT COUNT(*) FROM #FkAudit
    WHERE RowType = 'SUMMARY' AND UserTableCount >= 2 AND FkCount = 0
);
DECLARE @dbsWithTables int = (
    SELECT COUNT(*) FROM #FkAudit
    WHERE RowType = 'SUMMARY' AND UserTableCount >= 1
);

DECLARE @Result varchar(10);
DECLARE @Score int;
DECLARE @Finding nvarchar(max);
DECLARE @dbList nvarchar(max);

SELECT @dbList = STUFF((
    SELECT DISTINCT ', ' + DatabaseName
    FROM #FkAudit
    WHERE RowType IN ('SUMMARY','FK','ERROR')
    FOR XML PATH(''), TYPE
).value('.', 'nvarchar(max)'), 1, 2, '');

IF @dbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No accessible user databases were found to evaluate foreign key enforcement.';
END
ELSE IF @errCount > 0 AND @errCount = @dbCount
BEGIN
    SET @Score = 0;
    SET @Finding = 'Could not read catalog metadata in any accessible user database (' + CAST(@errCount AS varchar(11)) + ' error(s)).';
END
ELSE IF @totalUserTables = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user tables found in accessible databases; foreign key enforcement is not applicable. Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END
ELSE IF @disabledCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Found ' + CAST(@disabledCount AS varchar(11)) + ' disabled foreign key(s) across accessible databases (total FKs=' + CAST(@totalFks AS varchar(11)) + ', untrusted-enabled=' + CAST(@untrustedCount AS varchar(11)) + ', DBs with multi-table and zero FKs=' + CAST(@dbsWithTablesNoFk AS varchar(11)) + '). Disabled FKs do not enforce integrity. Sample: ' +
        ISNULL((
            SELECT TOP 1 DatabaseName + '.' + ParentSchema + '.' + ParentTable + ' -> ' + ReferencedSchema + '.' + ReferencedTable + ' [' + ForeignKeyName + ']'
            FROM #FkAudit WHERE RowType = 'FK' AND IsDisabled = 1
            ORDER BY DatabaseName, ParentSchema, ParentTable
        ), 'n/a') + '. Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END
ELSE IF @totalFks = 0 AND @dbsWithTablesNoFk > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'No foreign keys found while ' + CAST(@dbsWithTablesNoFk AS varchar(11)) + ' database(s) have 2+ user tables (user tables=' + CAST(@totalUserTables AS varchar(11)) + '). Referential integrity appears unenforced at the engine level. Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END
ELSE IF @totalFks = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'No foreign keys defined on ' + CAST(@totalUserTables AS varchar(11)) + ' user table(s) across accessible databases. Integrity may rely solely on application/ETL paths. Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END
ELSE IF @untrustedCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Found ' + CAST(@totalFks AS varchar(11)) + ' foreign key(s); ' + CAST(@untrustedCount AS varchar(11)) + ' are enabled but not trusted (created/re-enabled WITH NOCHECK). Untrusted FKs are not fully guaranteed by the optimizer and may hide existing violations. Sample: ' +
        ISNULL((
            SELECT TOP 1 DatabaseName + '.' + ParentSchema + '.' + ParentTable + ' -> ' + ReferencedSchema + '.' + ReferencedTable + ' [' + ForeignKeyName + ']'
            FROM #FkAudit WHERE RowType = 'FK' AND IsNotTrusted = 1 AND IsDisabled = 0
            ORDER BY DatabaseName, ParentSchema, ParentTable
        ), 'n/a') + '. Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'All foreign keys are enabled and trusted (' + CAST(@totalFks AS varchar(11)) + ' FK(s) across ' + CAST(@dbsWithTables AS varchar(11)) + ' database(s) with user tables; disabled=0, untrusted=0). Databases: ' + ISNULL(@dbList, N'n/a') + '.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    ISNULL(@dbList, 'none') AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #FkAudit;