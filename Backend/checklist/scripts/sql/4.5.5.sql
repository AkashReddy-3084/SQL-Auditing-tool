/* Checklist 4.5.5 - Constraints are TRUSTED (not disabled/untrusted)
   Read-only. Scope: DATABASE. Output: Result, Score, DatabaseQueried, Finding */
SET NOCOUNT ON;

DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(4000);
DECLARE @Finding         NVARCHAR(MAX);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#AuditDatabases') IS NOT NULL DROP TABLE #AuditDatabases;
CREATE TABLE #AuditDatabases
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#ConstraintState') IS NOT NULL DROP TABLE #ConstraintState;
CREATE TABLE #ConstraintState
(
    DatabaseName   SYSNAME      NOT NULL,
    ConstraintType NVARCHAR(20) NOT NULL,
    SchemaName     SYSNAME      NOT NULL,
    TableName      SYSNAME      NOT NULL,
    ConstraintName SYSNAME      NOT NULL,
    IsDisabled     BIT          NOT NULL,
    IsNotTrusted   BIT          NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #AuditDatabases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #AuditDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_distributor = 0
      AND d.name NOT IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db     SYSNAME;
DECLARE @prefix NVARCHAR(300);
DECLARE @sql    NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #AuditDatabases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        SET @sql = N'
SELECT @dbname, N''FOREIGN KEY'', s.name, t.name, fk.name, fk.is_disabled, fk.is_not_trusted
FROM ' + @prefix + N'sys.foreign_keys AS fk
INNER JOIN ' + @prefix + N'sys.tables AS t ON t.object_id = fk.parent_object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
WHERE fk.is_ms_shipped = 0
UNION ALL
SELECT @dbname, N''CHECK'', s.name, t.name, cc.name, cc.is_disabled, cc.is_not_trusted
FROM ' + @prefix + N'sys.check_constraints AS cc
INNER JOIN ' + @prefix + N'sys.tables AS t ON t.object_id = cc.parent_object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
WHERE cc.is_ms_shipped = 0;';

        INSERT INTO #ConstraintState
            (DatabaseName, ConstraintType, SchemaName, TableName, ConstraintName, IsDisabled, IsNotTrusted)
        EXEC sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
    END TRY
    BEGIN CATCH
        /* Database could not be read by the audit login - exclude it from scoring */
        DELETE FROM #AuditDatabases WHERE DatabaseName = @db;
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbCount               INT = (SELECT COUNT(*) FROM #AuditDatabases);
DECLARE @TotalConstraints      INT = (SELECT COUNT(*) FROM #ConstraintState);
DECLARE @DisabledCount         INT = (SELECT COUNT(*) FROM #ConstraintState WHERE IsDisabled = 1);
DECLARE @UntrustedEnabledCount INT = (SELECT COUNT(*) FROM #ConstraintState WHERE IsDisabled = 0 AND IsNotTrusted = 1);
DECLARE @AffectedCount         INT = (SELECT COUNT(*) FROM #ConstraintState WHERE IsDisabled = 1 OR IsNotTrusted = 1);
DECLARE @AffectedDbCount       INT = (SELECT COUNT(DISTINCT DatabaseName) FROM #ConstraintState WHERE IsDisabled = 1 OR IsNotTrusted = 1);
DECLARE @AffectedPct           DECIMAL(10, 2) =
    CASE WHEN (SELECT COUNT(*) FROM #ConstraintState) = 0 THEN 0.0
         ELSE CAST((SELECT COUNT(*) FROM #ConstraintState WHERE IsDisabled = 1 OR IsNotTrusted = 1) AS DECIMAL(18, 4))
              * 100.0 / (SELECT COUNT(*) FROM #ConstraintState)
    END;

DECLARE @Examples NVARCHAR(MAX) =
    STUFF((SELECT TOP (10)
               N'; ' + cs.DatabaseName + N': ' + cs.ConstraintType + N' '
               + QUOTENAME(cs.SchemaName) + N'.' + QUOTENAME(cs.TableName)
               + N'.' + QUOTENAME(cs.ConstraintName)
               + CASE WHEN cs.IsDisabled = 1 THEN N' (disabled)' ELSE N' (enabled but untrusted)' END
           FROM #ConstraintState AS cs
           WHERE cs.IsDisabled = 1 OR cs.IsNotTrusted = 1
           ORDER BY cs.IsDisabled DESC, cs.DatabaseName, cs.SchemaName, cs.TableName, cs.ConstraintName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = STUFF((SELECT N', ' + d.DatabaseName
                                  FROM #AuditDatabases AS d
                                  ORDER BY d.DatabaseName
                                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF LEN(@DatabaseQueried) > 3900
        SET @DatabaseQueried = LEFT(@DatabaseQueried, 3890) + N' ...';

    IF @TotalConstraints = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'No user-defined FOREIGN KEY or CHECK constraints exist in the '
                       + CAST(@DbCount AS NVARCHAR(20))
                       + N' evaluated database(s), so no disabled or untrusted constraints are present.';
    END
    ELSE IF @AffectedCount = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@TotalConstraints AS NVARCHAR(20))
                       + N' user FOREIGN KEY/CHECK constraints across ' + CAST(@DbCount AS NVARCHAR(20))
                       + N' database(s) are enabled and TRUSTED (is_disabled = 0 and is_not_trusted = 0), so the optimizer can rely on them.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
                        WHEN @AffectedPct <= 5.0  THEN 2
                        WHEN @AffectedPct <= 20.0 THEN 1
                        ELSE 0
                     END;
        SET @Finding = CAST(@AffectedCount AS NVARCHAR(20)) + N' of '
                       + CAST(@TotalConstraints AS NVARCHAR(20))
                       + N' user FOREIGN KEY/CHECK constraints ('
                       + CAST(@AffectedPct AS NVARCHAR(20)) + N'%) across '
                       + CAST(@AffectedDbCount AS NVARCHAR(20)) + N' of '
                       + CAST(@DbCount AS NVARCHAR(20))
                       + N' database(s) are not trusted by the optimizer: '
                       + CAST(@DisabledCount AS NVARCHAR(20)) + N' disabled and '
                       + CAST(@UntrustedEnabledCount AS NVARCHAR(20))
                       + N' enabled but untrusted (is_not_trusted = 1). Examples: '
                       + ISNULL(@Examples, N'n/a') + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(20))            AS Result,
    CAST(@Score AS INT)                      AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(4000)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(MAX))          AS Finding;

IF OBJECT_ID('tempdb..#ConstraintState') IS NOT NULL DROP TABLE #ConstraintState;
IF OBJECT_ID('tempdb..#AuditDatabases') IS NOT NULL DROP TABLE #AuditDatabases;