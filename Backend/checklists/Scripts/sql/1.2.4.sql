-- Checklist: Data flow lineage is traceable end-to-end from source to mart
-- Scope: DATABASE
-- Scoring: 3 = at least half the user tables carry lineage/audit columns and intra-database dependencies link consumers to producers; 2 = at least a fifth carry lineage columns, or some do and dependencies exist; 1 = only lineage columns or only dependencies exist; 0 = neither, or no user table to inspect

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Lineage evidence in the current database could not be inspected';
DECLARE @Total INT = 0;
DECLARE @Traced INT = 0;
DECLARE @Deps INT = 0;
DECLARE @Modules INT = 0;
DECLARE @Pct DECIMAL(9, 2) = 0;
DECLARE @Untraced NVARCHAR(MAX) = N'none';

BEGIN TRY
    SELECT @Total = COUNT(*) FROM sys.tables AS t WHERE t.is_ms_shipped = 0;

    -- a table is traceable when it records where its rows came from
    SELECT @Traced = COUNT(*)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0
      AND EXISTS (SELECT 1 FROM sys.columns AS c
                  WHERE c.object_id = t.object_id
                    AND LOWER(REPLACE(c.name, N'_', N'')) IN
                        (N'sourcesystem', N'sourcesystemid', N'sourcesystemname', N'sourcesystemcode',
                         N'sourcename', N'sourcetable', N'sourcefile', N'sourceid',
                         N'batchid', N'loadbatchid', N'etlbatchid', N'loadid', N'runid', N'etlrunid',
                         N'loaddate', N'loaddatetime', N'loadedat', N'loadts', N'etlloaddate',
                         N'dwloaddate', N'insertedat', N'createdby', N'lineageid', N'lineagekey'));

    -- object-to-object edges inside this database show how a mart is fed
    SELECT @Deps = COUNT(*)
    FROM sys.sql_expression_dependencies AS d
    WHERE d.referenced_id IS NOT NULL
      AND d.referenced_database_name IS NULL
      AND d.referenced_server_name IS NULL
      AND d.referencing_id <> d.referenced_id;

    SELECT @Modules = COUNT(*) FROM sys.sql_modules AS m
    JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE o.is_ms_shipped = 0;

    SET @Pct = ISNULL(100.0 * @Traced / NULLIF(CONVERT(DECIMAL(18, 4), @Total), 0), 0);

    SELECT @Untraced = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(SCHEMA_NAME(t.schema_id), N'.', t.name)), N', '), 400), N'none')
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM sys.columns AS c
                      WHERE c.object_id = t.object_id
                        AND LOWER(REPLACE(c.name, N'_', N'')) IN
                            (N'sourcesystem', N'sourcesystemid', N'sourcesystemname', N'sourcesystemcode',
                             N'sourcename', N'sourcetable', N'sourcefile', N'sourceid',
                             N'batchid', N'loadbatchid', N'etlbatchid', N'loadid', N'runid', N'etlrunid',
                             N'loaddate', N'loaddatetime', N'loadedat', N'loadts', N'etlloaddate',
                             N'dwloaddate', N'insertedat', N'createdby', N'lineageid', N'lineagekey'));

    SET @Score = CASE
        WHEN @Total = 0 THEN 0
        WHEN @Pct >= 50 AND @Deps > 0 THEN 3
        WHEN @Pct >= 20 OR (@Traced > 0 AND @Deps > 0) THEN 2
        WHEN @Traced > 0 OR @Deps > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CASE
        WHEN @Total = 0 THEN CONCAT(N'No user table exists in ', DB_NAME(), N', so no data flow could be traced')
        ELSE CONCAT(@Traced, N' of ', @Total, N' user tables (', @Pct,
             N'%) carry lineage/audit columns; ', @Deps,
             N' intra-database dependency edges across ', @Modules,
             N' T-SQL modules; tables without lineage columns: ', @Untraced) END;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read lineage metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
