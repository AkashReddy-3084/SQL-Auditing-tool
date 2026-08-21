/*
    Checklist Item : 4.5.1 - Primary keys defined on all tables
    Scope          : DATABASE (all accessible user databases)
    Type           : Read-only. Queries catalog views only (sys.tables, sys.schemas, sys.key_constraints).
                     No DDL, no DML against user objects, no configuration change.
*/

SET NOCOUNT ON;

DECLARE @TableInfo TABLE
(
    DatabaseName  SYSNAME NOT NULL,
    SchemaName    SYSNAME NOT NULL,
    TableName     SYSNAME NOT NULL,
    HasPrimaryKey BIT     NOT NULL
);

DECLARE @DbScanned TABLE
(
    DatabaseName SYSNAME NOT NULL
);

DECLARE @EngineEdition   INT           = ISNULL(CAST(SERVERPROPERTY('EngineEdition') AS INT), 0);
DECLARE @DbName          SYSNAME;
DECLARE @Sql             NVARCHAR(MAX);
DECLARE @Prefix          NVARCHAR(300);
DECLARE @DbLiteral       NVARCHAR(300);
DECLARE @TemporalFilter  NVARCHAR(200) = N'';

-- temporal_type exists only on SQL Server 2016+/Azure; history tables cannot carry a primary key.
IF EXISTS (SELECT 1 FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.tables') AND name = 'temporal_type')
    SET @TemporalFilter = N' AND t.temporal_type <> 1';

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database queries are not supported, inspect the current database only. */
    SET @Prefix    = N'sys.';
    SET @DbLiteral = N'DB_NAME()';

    SET @Sql = N'
        SELECT ' + @DbLiteral + N', s.name, t.name,
               CASE WHEN EXISTS (SELECT 1
                                 FROM ' + @Prefix + N'key_constraints kc
                                 WHERE kc.parent_object_id = t.object_id
                                   AND kc.type = ''PK'')
                    THEN 1 ELSE 0 END
        FROM ' + @Prefix + N'tables t
        INNER JOIN ' + @Prefix + N'schemas s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
          AND t.type = ''U''
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')' + @TemporalFilter + N';';

    BEGIN TRY
        INSERT INTO @TableInfo (DatabaseName, SchemaName, TableName, HasPrimaryKey)
        EXEC sp_executesql @Sql;

        INSERT INTO @DbScanned (DatabaseName) VALUES (DB_NAME());
    END TRY
    BEGIN CATCH
        /* Current database not readable - leave it out of the scanned set. */
        SET @Sql = NULL;
    END CATCH
END
ELSE
BEGIN
    /* Box / Managed Instance: walk every online, accessible, non-snapshot user database. */
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
          AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Prefix    = QUOTENAME(@DbName) + N'.sys.';
        SET @DbLiteral = QUOTENAME(@DbName, '''');

        SET @Sql = N'
            SELECT ' + @DbLiteral + N', s.name, t.name,
                   CASE WHEN EXISTS (SELECT 1
                                     FROM ' + @Prefix + N'key_constraints kc
                                     WHERE kc.parent_object_id = t.object_id
                                       AND kc.type = ''PK'')
                        THEN 1 ELSE 0 END
            FROM ' + @Prefix + N'tables t
            INNER JOIN ' + @Prefix + N'schemas s ON s.schema_id = t.schema_id
            WHERE t.is_ms_shipped = 0
              AND t.type = ''U''
              AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')' + @TemporalFilter + N';';

        BEGIN TRY
            INSERT INTO @TableInfo (DatabaseName, SchemaName, TableName, HasPrimaryKey)
            EXEC sp_executesql @Sql;

            INSERT INTO @DbScanned (DatabaseName) VALUES (@DbName);
        END TRY
        BEGIN CATCH
            /* Database offline, recovering or permission denied - skip it. */
            SET @Sql = NULL;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

/* Every aggregate below is wrapped so that zero rows can never produce a NULL output column. */
DECLARE @DbCount      INT = ISNULL((SELECT COUNT(*) FROM @DbScanned), 0);
DECLARE @TotalTables  INT = ISNULL((SELECT COUNT(*) FROM @TableInfo), 0);
DECLARE @TablesWithPK INT = ISNULL((SELECT COUNT(*) FROM @TableInfo WHERE HasPrimaryKey = 1), 0);
DECLARE @TablesNoPK   INT = ISNULL((SELECT COUNT(*) FROM @TableInfo WHERE HasPrimaryKey = 0), 0);
DECLARE @DbWithGaps   INT = ISNULL((SELECT COUNT(DISTINCT DatabaseName) FROM @TableInfo WHERE HasPrimaryKey = 0), 0);

DECLARE @PctWithPK DECIMAL(5, 2) =
    ISNULL(CASE WHEN @TotalTables = 0 THEN CAST(100.00 AS DECIMAL(5, 2))
                ELSE CAST((@TablesWithPK * 100.0) / @TotalTables AS DECIMAL(5, 2))
           END, CAST(0.00 AS DECIMAL(5, 2)));

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    ISNULL(
        STUFF(ISNULL((SELECT N', ' + DatabaseName
                      FROM @DbScanned
                      ORDER BY DatabaseName
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N''), 1, 2, N''),
        N'None');

IF @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
    SET @DatabaseQueried = N'None';

DECLARE @Sample NVARCHAR(MAX) =
    ISNULL(
        STUFF(ISNULL((SELECT TOP (10) N'; ' + DatabaseName + N'.' + SchemaName + N'.' + TableName
                      FROM @TableInfo
                      WHERE HasPrimaryKey = 0
                      ORDER BY DatabaseName, SchemaName, TableName
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N''), 1, 2, N''),
        N'');

DECLARE @Result  NVARCHAR(20) = N'NeedsReview';
DECLARE @Score   INT          = 0;
DECLARE @Finding NVARCHAR(MAX) = N'Primary key coverage could not be determined.';

IF @DbCount = 0
BEGIN
    SET @Result  = N'NeedsReview';
    SET @Score   = 0;
    SET @Finding = N'No user database could be inspected: none present, offline, or the audit login lacks access. Primary key coverage could not be determined.';
END
ELSE IF @TotalTables = 0
BEGIN
    SET @Result  = N'Pass';
    SET @Score   = 3;
    SET @Finding = N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s); no user tables exist, so there are no tables missing a primary key.';
END
ELSE
BEGIN
    SET @Score =
        CASE WHEN @PctWithPK = 100.00 THEN 3
             WHEN @PctWithPK >= 95.00  THEN 2
             WHEN @PctWithPK >= 80.00  THEN 1
             ELSE 0
        END;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding =
        N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s) and ' + CAST(@TotalTables AS NVARCHAR(10)) +
        N' user table(s): ' + CAST(@TablesWithPK AS NVARCHAR(10)) + N' have a primary key, ' +
        CAST(@TablesNoPK AS NVARCHAR(10)) + N' do not (' + CAST(@PctWithPK AS NVARCHAR(20)) + N'% coverage across ' +
        CAST(@DbWithGaps AS NVARCHAR(10)) + N' database(s) with gaps).' +
        CASE WHEN LEN(@Sample) = 0 THEN N' Every user table has a primary key defined.'
             ELSE N' Tables without a primary key (first 10): ' + @Sample + N'.'
        END;
END

SELECT
    ISNULL(@Result, N'NeedsReview')                                  AS Result,
    ISNULL(@Score, 0)                                                AS Score,
    ISNULL(@DatabaseQueried, N'None')                                AS DatabaseQueried,
    ISNULL(@Finding, N'Primary key coverage could not be determined.') AS Finding;