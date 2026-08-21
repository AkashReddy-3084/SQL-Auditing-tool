SET NOCOUNT ON;

-- 5.4.5 Categorical / Enum: values within expected domain; no invalid codes
-- Read-only: inspects catalog metadata only.

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
CREATE TABLE #Databases
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#CategoricalColumns') IS NOT NULL DROP TABLE #CategoricalColumns;
CREATE TABLE #CategoricalColumns
(
    DatabaseName       sysname NOT NULL,
    SchemaName         sysname NOT NULL,
    TableName          sysname NOT NULL,
    ColumnName         sysname NOT NULL,
    DataTypeName       sysname NOT NULL,
    HasCheckConstraint bit     NOT NULL,
    HasForeignKey      bit     NOT NULL,
    HasWeakConstraint  bit     NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName sysname;
DECLARE @QuotedDb nvarchar(258);
DECLARE @Sql nvarchar(max);

DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN DbCursor;
FETCH NEXT FROM DbCursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @QuotedDb = QUOTENAME(@DbName);

        SET @Sql = N'
        SELECT
            @p_db AS DatabaseName,
            s.name AS SchemaName,
            t.name AS TableName,
            c.name AS ColumnName,
            ty.name AS DataTypeName,
            CASE WHEN EXISTS (
                    SELECT 1
                    FROM ' + @QuotedDb + N'.sys.check_constraints AS cc
                    WHERE cc.parent_object_id = t.object_id
                      AND (
                            cc.parent_column_id = c.column_id
                            OR EXISTS (
                                SELECT 1
                                FROM ' + @QuotedDb + N'.sys.sql_expression_dependencies AS d
                                WHERE d.referencing_id = cc.object_id
                                  AND d.referenced_id = t.object_id
                                  AND d.referenced_minor_id = c.column_id
                            )
                          )
                 ) THEN 1 ELSE 0 END AS HasCheckConstraint,
            CASE WHEN EXISTS (
                    SELECT 1
                    FROM ' + @QuotedDb + N'.sys.foreign_key_columns AS fkc
                    WHERE fkc.parent_object_id = t.object_id
                      AND fkc.parent_column_id = c.column_id
                 ) THEN 1 ELSE 0 END AS HasForeignKey,
            CASE WHEN EXISTS (
                    SELECT 1
                    FROM ' + @QuotedDb + N'.sys.check_constraints AS cw
                    WHERE cw.parent_object_id = t.object_id
                      AND (cw.is_disabled = 1 OR cw.is_not_trusted = 1)
                      AND (
                            cw.parent_column_id = c.column_id
                            OR EXISTS (
                                SELECT 1
                                FROM ' + @QuotedDb + N'.sys.sql_expression_dependencies AS dw
                                WHERE dw.referencing_id = cw.object_id
                                  AND dw.referenced_id = t.object_id
                                  AND dw.referenced_minor_id = c.column_id
                            )
                          )
                 )
                 OR EXISTS (
                    SELECT 1
                    FROM ' + @QuotedDb + N'.sys.foreign_keys AS fk
                    INNER JOIN ' + @QuotedDb + N'.sys.foreign_key_columns AS fw
                        ON fw.constraint_object_id = fk.object_id
                    WHERE fw.parent_object_id = t.object_id
                      AND fw.parent_column_id = c.column_id
                      AND (fk.is_disabled = 1 OR fk.is_not_trusted = 1)
                 ) THEN 1 ELSE 0 END AS HasWeakConstraint
        FROM ' + @QuotedDb + N'.sys.columns AS c
        INNER JOIN ' + @QuotedDb + N'.sys.tables AS t
            ON t.object_id = c.object_id
        INNER JOIN ' + @QuotedDb + N'.sys.schemas AS s
            ON s.schema_id = t.schema_id
        INNER JOIN ' + @QuotedDb + N'.sys.types AS ty
            ON ty.system_type_id = c.system_type_id
           AND ty.user_type_id = ty.system_type_id
        WHERE t.is_ms_shipped = 0
          AND c.is_computed = 0
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
          AND (
                (ty.name IN (''char'', ''nchar'', ''varchar'', ''nvarchar'') AND c.max_length BETWEEN 1 AND 60)
                OR ty.name IN (''tinyint'', ''smallint'')
              )
          AND (
                c.name LIKE ''%status%''   OR c.name LIKE ''%type%''     OR c.name LIKE ''%code%''
             OR c.name LIKE ''%state%''    OR c.name LIKE ''%categ%''    OR c.name LIKE ''%class%''
             OR c.name LIKE ''%kind%''     OR c.name LIKE ''%level%''    OR c.name LIKE ''%flag%''
             OR c.name LIKE ''%mode%''     OR c.name LIKE ''%method%''   OR c.name LIKE ''%priority%''
             OR c.name LIKE ''%severity%'' OR c.name LIKE ''%gender%''   OR c.name LIKE ''%currency%''
             OR c.name LIKE ''%country%''  OR c.name LIKE ''%region%''   OR c.name LIKE ''%lang%''
              );';

        INSERT INTO #CategoricalColumns
            (DatabaseName, SchemaName, TableName, ColumnName, DataTypeName,
             HasCheckConstraint, HasForeignKey, HasWeakConstraint)
        EXEC sp_executesql @Sql, N'@p_db sysname', @p_db = @DbName;
    END TRY
    BEGIN CATCH
        -- Database not readable by this login; skip it and continue.
        DELETE FROM #Databases WHERE DatabaseName = @DbName;
    END CATCH

    FETCH NEXT FROM DbCursor INTO @DbName;
END

CLOSE DbCursor;
DEALLOCATE DbCursor;

DECLARE @DbCount    int = (SELECT COUNT(*) FROM #Databases);
DECLARE @Total      int = 0;
DECLARE @Enforced   int = 0;
DECLARE @Weak       int = 0;
DECLARE @Unenforced int = 0;
DECLARE @Coverage   decimal(6,2) = 0;

SELECT
    @Total    = COUNT(*),
    @Enforced = SUM(CASE WHEN HasCheckConstraint = 1 OR HasForeignKey = 1 THEN 1 ELSE 0 END),
    @Weak     = SUM(CASE WHEN HasWeakConstraint = 1 THEN 1 ELSE 0 END)
FROM #CategoricalColumns;

SET @Total    = ISNULL(@Total, 0);
SET @Enforced = ISNULL(@Enforced, 0);
SET @Weak     = ISNULL(@Weak, 0);
SET @Unenforced = @Total - @Enforced;

DECLARE @DbList nvarchar(max);
SELECT @DbList = STUFF((
    SELECT N', ' + d.DatabaseName
    FROM #Databases AS d
    ORDER BY d.DatabaseName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DbList IS NULL OR LEN(@DbList) = 0
    SET @DbList = N'None';
IF LEN(@DbList) > 250
    SET @DbList = LEFT(@DbList, 247) + N'...';

DECLARE @Examples nvarchar(max);
SELECT @Examples = STUFF((
    SELECT N', ' + x.DatabaseName + N'.' + x.SchemaName + N'.' + x.TableName + N'.' + x.ColumnName
    FROM (
        SELECT TOP (5) cc.DatabaseName, cc.SchemaName, cc.TableName, cc.ColumnName
        FROM #CategoricalColumns AS cc
        WHERE cc.HasCheckConstraint = 0 AND cc.HasForeignKey = 0
        ORDER BY cc.DatabaseName, cc.SchemaName, cc.TableName, cc.ColumnName
    ) AS x
    ORDER BY x.DatabaseName, x.SchemaName, x.TableName, x.ColumnName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Score   int;
DECLARE @Result  nvarchar(20);
DECLARE @Finding nvarchar(max);

IF @Total = 0
BEGIN
    SET @Score = 2;
    SET @Result = N'Review';
    SET @Finding = N'No candidate categorical/enum columns were identified across '
                 + CAST(@DbCount AS nvarchar(20))
                 + N' accessible user database(s). Domain validity for categorical values could not be measured from catalog metadata; manual review of the data model is required.';
END
ELSE
BEGIN
    SET @Coverage = CAST(@Enforced AS decimal(12,2)) * 100.0 / CAST(@Total AS decimal(12,2));

    IF @Coverage >= 90 AND @Weak = 0
        SET @Score = 3;
    ELSE IF @Coverage >= 60
        SET @Score = 2;
    ELSE IF @Coverage >= 25
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' WHEN @Score = 2 THEN N'Review' ELSE N'Fail' END;

    SET @Finding = N'Across ' + CAST(@DbCount AS nvarchar(20)) + N' accessible user database(s), '
                 + CAST(@Total AS nvarchar(20)) + N' candidate categorical/enum column(s) were identified; '
                 + CAST(@Enforced AS nvarchar(20)) + N' ('
                 + CAST(@Coverage AS nvarchar(20))
                 + N'%) have an in-engine domain declaration via CHECK constraint or foreign key to a lookup table, and '
                 + CAST(@Unenforced AS nvarchar(20)) + N' have no domain enforcement at all. '
                 + CAST(@Weak AS nvarchar(20))
                 + N' enforced column(s) rely on a CHECK or foreign key constraint that is disabled or NOT TRUSTED, so invalid codes may already be stored.'
                 + CASE WHEN @Examples IS NULL THEN N''
                        ELSE N' Unenforced examples: ' + @Examples + N'.' END;
END

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#CategoricalColumns') IS NOT NULL DROP TABLE #CategoricalColumns;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;