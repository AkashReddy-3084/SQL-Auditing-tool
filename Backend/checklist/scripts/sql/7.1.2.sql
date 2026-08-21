SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#DbInv') IS NOT NULL DROP TABLE #DbInv;
IF OBJECT_ID(N'tempdb..#Class') IS NOT NULL DROP TABLE #Class;

CREATE TABLE #DbInv
(
    DbName          sysname NOT NULL PRIMARY KEY,
    UserTableCount  INT     NOT NULL
);

CREATE TABLE #Class
(
    DbName           sysname        NOT NULL,
    SchemaName       sysname        NULL,
    TableName        sysname        NULL,
    ColumnName       sysname        NULL,
    InformationType  NVARCHAR(256)  NULL,
    SensitivityLabel NVARCHAR(256)  NULL,
    SourceType       NVARCHAR(50)   NULL
);

DECLARE @IsAzureDb   BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY(N'EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @Sql         NVARCHAR(MAX);
DECLARE @DbName      sysname;

DECLARE @CollectSql NVARCHAR(MAX) = N'
INSERT INTO #DbInv (DbName, UserTableCount)
SELECT DB_NAME(), COUNT(*)
FROM sys.tables
WHERE is_ms_shipped = 0;

IF EXISTS (SELECT 1 FROM sys.system_objects WHERE name = N''sensitivity_classifications'' AND schema_id = SCHEMA_ID(N''sys''))
BEGIN
    INSERT INTO #Class (DbName, SchemaName, TableName, ColumnName, InformationType, SensitivityLabel, SourceType)
    SELECT DB_NAME(), sch.name, t.name, c.name,
           NULLIF(LTRIM(RTRIM(sc.information_type)), N''''),
           NULLIF(LTRIM(RTRIM(sc.label)), N''''),
           N''DataClassification''
    FROM sys.sensitivity_classifications AS sc
    INNER JOIN sys.columns  AS c   ON c.object_id = sc.major_id AND c.column_id = sc.minor_id
    INNER JOIN sys.tables   AS t   ON t.object_id = c.object_id
    INNER JOIN sys.schemas  AS sch ON sch.schema_id = t.schema_id
    WHERE sc.class = 1 AND t.is_ms_shipped = 0;
END;

INSERT INTO #Class (DbName, SchemaName, TableName, ColumnName, InformationType, SensitivityLabel, SourceType)
SELECT DB_NAME(), sch.name, t.name, c.name,
       NULLIF(LTRIM(RTRIM(MAX(CASE WHEN ep.name = N''sys_information_type_name''  THEN CONVERT(NVARCHAR(256), ep.value) END))), N''''),
       NULLIF(LTRIM(RTRIM(MAX(CASE WHEN ep.name = N''sys_sensitivity_label_name'' THEN CONVERT(NVARCHAR(256), ep.value) END))), N''''),
       N''ExtendedProperty''
FROM sys.extended_properties AS ep
INNER JOIN sys.columns  AS c   ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
INNER JOIN sys.tables   AS t   ON t.object_id = c.object_id
INNER JOIN sys.schemas  AS sch ON sch.schema_id = t.schema_id
WHERE ep.class = 1
  AND ep.name IN (N''sys_information_type_name'', N''sys_sensitivity_label_name'')
  AND t.is_ms_shipped = 0
GROUP BY sch.name, t.name, c.name;';

IF @IsAzureDb = 1
BEGIN
    BEGIN TRY
        EXEC sys.sp_executesql @CollectSql;
    END TRY
    BEGIN CATCH
        /* database not readable by this principal - leave it uncounted */
    END CATCH;
END
ELSE
BEGIN
    DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN DbCursor;
    FETCH NEXT FROM DbCursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @CollectSql;
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* database not readable by this principal - leave it uncounted */
        END CATCH;

        FETCH NEXT FROM DbCursor INTO @DbName;
    END;

    CLOSE DbCursor;
    DEALLOCATE DbCursor;
END;

DECLARE @DbsWithTables      INT;
DECLARE @DbsClassified      INT;
DECLARE @ClassifiedColumns  INT;
DECLARE @DistinctTypes      INT;
DECLARE @TypeList           NVARCHAR(MAX);
DECLARE @DatabaseQueried    NVARCHAR(MAX);
DECLARE @Result             NVARCHAR(20);
DECLARE @Score              INT;
DECLARE @Finding            NVARCHAR(MAX);

SELECT @DbsWithTables = COUNT(*)
FROM #DbInv
WHERE UserTableCount > 0;

SELECT @ClassifiedColumns = COUNT(*)
FROM (
    SELECT DISTINCT DbName, SchemaName, TableName, ColumnName
    FROM #Class
    WHERE InformationType IS NOT NULL OR SensitivityLabel IS NOT NULL
) AS DistinctCols;

SELECT @DbsClassified = COUNT(DISTINCT c.DbName)
FROM #Class AS c
INNER JOIN #DbInv AS d ON d.DbName = c.DbName
WHERE d.UserTableCount > 0
  AND (c.InformationType IS NOT NULL OR c.SensitivityLabel IS NOT NULL);

SELECT @DistinctTypes = COUNT(DISTINCT InformationType)
FROM #Class
WHERE InformationType IS NOT NULL;

SELECT @TypeList = STUFF((
        SELECT DISTINCT N', ' + InformationType
        FROM #Class
        WHERE InformationType IS NOT NULL
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + DbName
        FROM #DbInv
        ORDER BY DbName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'None (no accessible user databases)');
IF LEN(@DatabaseQueried) > 500
    SET @DatabaseQueried = LEFT(@DatabaseQueried, 497) + N'...';

SET @TypeList = ISNULL(@TypeList, N'none');
IF LEN(@TypeList) > 400
    SET @TypeList = LEFT(@TypeList, 397) + N'...';

SET @DbsWithTables     = ISNULL(@DbsWithTables, 0);
SET @DbsClassified     = ISNULL(@DbsClassified, 0);
SET @ClassifiedColumns = ISNULL(@ClassifiedColumns, 0);
SET @DistinctTypes     = ISNULL(@DistinctTypes, 0);

IF @DbsWithTables = 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'No accessible user database containing user tables was found, so no regulated data inventory could be evaluated from SQL Server metadata. Databases inspected: ' + @DatabaseQueried + N'. Manually confirm that no in-scope regulated data is hosted on this instance.';
END
ELSE IF @ClassifiedColumns = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'No sensitivity classification and no classification extended property was found in any of the ' + CONVERT(NVARCHAR(10), @DbsWithTables) + N' user database(s) holding user tables. In-scope regulated data categories have not been identified or inventoried in SQL Server.';
END
ELSE IF @DbsClassified < @DbsWithTables OR @DistinctTypes = 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Partial inventory: ' + CONVERT(NVARCHAR(10), @ClassifiedColumns) + N' classified column(s) across ' + CONVERT(NVARCHAR(10), @DbsClassified) + N' of ' + CONVERT(NVARCHAR(10), @DbsWithTables) + N' user database(s) with user tables. Distinct information types recorded: ' + CONVERT(NVARCHAR(10), @DistinctTypes) + N' (' + @TypeList + N'). Remaining databases show no evidence of regulated data category identification.';
END
ELSE
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CONVERT(NVARCHAR(10), @DbsWithTables) + N' user database(s) with user tables carry sensitivity classifications: ' + CONVERT(NVARCHAR(10), @ClassifiedColumns) + N' classified column(s) covering ' + CONVERT(NVARCHAR(10), @DistinctTypes) + N' distinct information type(s) (' + @TypeList + N'). Regulated data categories are identified and inventoried.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID(N'tempdb..#DbInv') IS NOT NULL DROP TABLE #DbInv;
IF OBJECT_ID(N'tempdb..#Class') IS NOT NULL DROP TABLE #Class;