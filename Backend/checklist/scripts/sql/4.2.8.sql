SET NOCOUNT ON;

DECLARE @Result varchar(10) = 'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(max) = N'None';
DECLARE @Finding nvarchar(max) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList (DbName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#ScdResults') IS NOT NULL DROP TABLE #ScdResults;
CREATE TABLE #ScdResults (
    DbName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    HasCanonical bit NOT NULL
);

DECLARE @IsAzure bit =
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF @IsAzure = 1
BEGIN
    INSERT INTO #DbList (DbName) SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.state = 0
      AND d.database_id > 4
      AND HAS_DBACCESS(d.name) = 1;
END

IF NOT EXISTS (SELECT 1 FROM #DbList)
BEGIN
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END

DECLARE @Db sysname;
DECLARE @Sql nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #DbList ORDER BY DbName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @IsAzure = 1
    BEGIN
        SET @Sql = N'
INSERT INTO #ScdResults (DbName, SchemaName, TableName, HasCanonical)
SELECT
    DB_NAME(),
    s.name,
    t.name,
    CASE
        WHEN MAX(CASE WHEN LOWER(c.name) IN (N''valid_from'', N''validfrom'') THEN 1 ELSE 0 END) = 1
         AND MAX(CASE WHEN LOWER(c.name) IN (N''valid_to'', N''validto'') THEN 1 ELSE 0 END) = 1
         AND MAX(CASE WHEN LOWER(c.name) IN (N''is_current'', N''iscurrent'') THEN 1 ELSE 0 END) = 1
        THEN 1 ELSE 0
    END
FROM sys.tables t
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name
HAVING
    MAX(CASE WHEN LOWER(c.name) IN (
            N''valid_from'', N''validfrom'', N''effective_date'', N''effectivedate'',
            N''start_date'', N''startdate'', N''scd_from'', N''row_valid_from''
        ) THEN 1 ELSE 0 END) = 1
    AND (
        MAX(CASE WHEN LOWER(c.name) IN (
                N''valid_to'', N''validto'', N''end_date'', N''enddate'',
                N''expiry_date'', N''expirydate'', N''scd_to'', N''row_valid_to''
            ) THEN 1 ELSE 0 END) = 1
        OR MAX(CASE WHEN LOWER(c.name) IN (
                N''is_current'', N''iscurrent'', N''current_flag'', N''currentflag'',
                N''is_active'', N''isactive'', N''active_flag'', N''activeflag''
            ) THEN 1 ELSE 0 END) = 1
    );';
    END
    ELSE
    BEGIN
        SET @Sql = N'
INSERT INTO #ScdResults (DbName, SchemaName, TableName, HasCanonical)
SELECT
    N' + QUOTENAME(@Db, '''') + N',
    s.name,
    t.name,
    CASE
        WHEN MAX(CASE WHEN LOWER(c.name) IN (N''valid_from'', N''validfrom'') THEN 1 ELSE 0 END) = 1
         AND MAX(CASE WHEN LOWER(c.name) IN (N''valid_to'', N''validto'') THEN 1 ELSE 0 END) = 1
         AND MAX(CASE WHEN LOWER(c.name) IN (N''is_current'', N''iscurrent'') THEN 1 ELSE 0 END) = 1
        THEN 1 ELSE 0
    END
FROM ' + QUOTENAME(@Db) + N'.sys.tables t
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.schemas s ON s.schema_id = t.schema_id
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.columns c ON c.object_id = t.object_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name
HAVING
    MAX(CASE WHEN LOWER(c.name) IN (
            N''valid_from'', N''validfrom'', N''effective_date'', N''effectivedate'',
            N''start_date'', N''startdate'', N''scd_from'', N''row_valid_from''
        ) THEN 1 ELSE 0 END) = 1
    AND (
        MAX(CASE WHEN LOWER(c.name) IN (
                N''valid_to'', N''validto'', N''end_date'', N''enddate'',
                N''expiry_date'', N''expirydate'', N''scd_to'', N''row_valid_to''
            ) THEN 1 ELSE 0 END) = 1
        OR MAX(CASE WHEN LOWER(c.name) IN (
                N''is_current'', N''iscurrent'', N''current_flag'', N''currentflag'',
                N''is_active'', N''isactive'', N''active_flag'', N''activeflag''
            ) THEN 1 ELSE 0 END) = 1
    );';
    END

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @Sql = NULL;
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @Db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = ISNULL(STUFF((
    SELECT N', ' + d.DbName
    FROM #DbList d
    ORDER BY d.DbName
    FOR XML PATH(N''), TYPE
).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'None');

IF LTRIM(RTRIM(@DatabaseQueried)) = N''
    SET @DatabaseQueried = N'None';

DECLARE @CandidateCount int = ISNULL((SELECT COUNT(*) FROM #ScdResults), 0);
DECLARE @CompliantCount int = ISNULL((SELECT COUNT(*) FROM #ScdResults WHERE HasCanonical = 1), 0);
DECLARE @Pct decimal(5, 2) =
    CASE
        WHEN @CandidateCount = 0 THEN 100.00
        ELSE CAST(@CompliantCount AS decimal(5, 2)) * 100.0
             / CAST(@CandidateCount AS decimal(5, 2))
    END;

IF @CandidateCount = 0
BEGIN
    SET @Score = 3;
    SET @Result = 'Pass';
    SET @Finding = N'No SCD Type 2 candidate tables found in queried database(s); check is N/A where SCD2 is not used. Databases: '
                  + ISNULL(@DatabaseQueried, N'None') + N'.';
END
ELSE
BEGIN
    SET @Score =
        CASE
            WHEN @Pct >= 100.00 THEN 3
            WHEN @Pct >= 70.00 THEN 2
            WHEN @Pct >= 40.00 THEN 1
            ELSE 0
        END;
    SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;

    DECLARE @Sample nvarchar(max);
    SET @Sample = ISNULL(STUFF((
        SELECT TOP (8)
            N'; ' + r.DbName + N'.' + r.SchemaName + N'.' + r.TableName
        FROM #ScdResults r
        WHERE r.HasCanonical = 0
        ORDER BY r.DbName, r.SchemaName, r.TableName
        FOR XML PATH(N''), TYPE
    ).value(N'.', N'nvarchar(max)'), 1, 1, N''), N'');

    SET @Finding =
        N'SCD2 candidates: ' + CAST(@CandidateCount AS nvarchar(20))
      + N'; with canonical valid_from/valid_to/is_current: '
      + CAST(@CompliantCount AS nvarchar(20))
      + N' (' + CAST(CAST(ROUND(@Pct, 0) AS int) AS nvarchar(10)) + N'%).';

    IF @Sample <> N''
        SET @Finding = @Finding + N' Non-canonical samples:' + @Sample;

    SET @Finding = @Finding + N' Databases: ' + ISNULL(@DatabaseQueried, N'None') + N'.';
END

IF ISNULL(@DatabaseQueried, N'None') = N'None'
BEGIN
    SET @Result = 'Fail';
    SET @Score = 0;
    SET @Finding = N'No database found to be queried';
    SET @DatabaseQueried = N'None';
END

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;