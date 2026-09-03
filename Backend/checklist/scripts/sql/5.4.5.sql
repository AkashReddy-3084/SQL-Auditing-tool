SET NOCOUNT ON;

DECLARE @IsAzureBit BIT = CASE WHEN SERVERPROPERTY('EngineEdition') = 5 THEN 1 ELSE 0 END;
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);

DECLARE @Agg TABLE (
    DatabaseName NVARCHAR(128) NOT NULL,
    CandidateCols INT NOT NULL,
    CheckEnforced INT NOT NULL,
    FkEnforced INT NOT NULL,
    DomainEnforced INT NOT NULL,
    Unenforced INT NOT NULL
);

IF @IsAzureBit = 1
BEGIN
    SET @DbName = DB_NAME();

    ;WITH Cols AS (
        SELECT
            c.object_id,
            c.column_id,
            c.name AS ColumnName,
            ty.name AS TypeName,
            c.max_length
        FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        INNER JOIN sys.columns c ON c.object_id = t.object_id
        INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        WHERE t.is_ms_shipped = 0
          AND c.is_identity = 0
          AND c.is_computed = 0
          AND ty.name IN ('char','nchar','varchar','nvarchar','tinyint','smallint','int','bigint','bit')
          AND (
                c.name LIKE '%status%'
             OR c.name LIKE '%type%'
             OR c.name LIKE '%code%'
             OR c.name LIKE '%flag%'
             OR c.name LIKE '%category%'
             OR c.name LIKE '%state%'
             OR c.name LIKE '%level%'
             OR c.name LIKE '%gender%'
             OR c.name LIKE '%priority%'
             OR c.name LIKE '%class%'
             OR c.name LIKE '%mode%'
             OR c.name LIKE '%reason%'
             OR c.name LIKE '%result%'
             OR c.name LIKE '%enum%'
             OR (ty.name IN ('char','nchar') AND c.max_length BETWEEN 1 AND 20)
             OR (ty.name IN ('varchar','nvarchar') AND c.max_length BETWEEN 2 AND 40)
             OR ty.name IN ('tinyint','bit')
          )
    ),
    CheckCols AS (
        SELECT DISTINCT
            c.object_id,
            c.column_id
        FROM sys.check_constraints chk
        INNER JOIN sys.columns c
            ON c.object_id = chk.parent_object_id
        WHERE chk.is_disabled = 0
          AND chk.is_not_trusted = 0
          AND (
                chk.definition LIKE '% IN (%'
             OR chk.definition LIKE '% in (%'
          )
          AND (
                CHARINDEX(QUOTENAME(c.name), chk.definition) > 0
             OR CHARINDEX(c.name, chk.definition) > 0
          )
    ),
    FkCols AS (
        SELECT DISTINCT
            fkc.parent_object_id AS object_id,
            fkc.parent_column_id AS column_id
        FROM sys.foreign_keys fk
        INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        WHERE fk.is_disabled = 0
          AND fk.is_not_trusted = 0
    ),
    Scored AS (
        SELECT
            CASE WHEN cc.column_id IS NOT NULL THEN 1 ELSE 0 END AS HasCheck,
            CASE WHEN fk.column_id IS NOT NULL THEN 1 ELSE 0 END AS HasFk
        FROM Cols col
        LEFT JOIN CheckCols cc
            ON cc.object_id = col.object_id AND cc.column_id = col.column_id
        LEFT JOIN FkCols fk
            ON fk.object_id = col.object_id AND fk.column_id = col.column_id
    )
    INSERT INTO @Agg (DatabaseName, CandidateCols, CheckEnforced, FkEnforced, DomainEnforced, Unenforced)
    SELECT
        @DbName,
        COUNT(*),
        ISNULL(SUM(HasCheck), 0),
        ISNULL(SUM(HasFk), 0),
        ISNULL(SUM(CASE WHEN HasCheck = 1 OR HasFk = 1 THEN 1 ELSE 0 END), 0),
        ISNULL(SUM(CASE WHEN HasCheck = 0 AND HasFk = 0 THEN 1 ELSE 0 END), 0)
    FROM Scored;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = 'ONLINE'
          AND HAS_DBACCESS(name) = 1
          AND is_read_only = 0
          AND name NOT IN ('distribution', 'SSISDB');

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
        ;WITH Cols AS (
            SELECT
                c.object_id,
                c.column_id,
                c.name AS ColumnName,
                ty.name AS TypeName,
                c.max_length
            FROM ' + QUOTENAME(@DbName) + N'.sys.tables t
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON s.schema_id = t.schema_id
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c ON c.object_id = t.object_id
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
            WHERE t.is_ms_shipped = 0
              AND c.is_identity = 0
              AND c.is_computed = 0
              AND ty.name IN (''char'',''nchar'',''varchar'',''nvarchar'',''tinyint'',''smallint'',''int'',''bigint'',''bit'')
              AND (
                    c.name LIKE ''%status%''
                 OR c.name LIKE ''%type%''
                 OR c.name LIKE ''%code%''
                 OR c.name LIKE ''%flag%''
                 OR c.name LIKE ''%category%''
                 OR c.name LIKE ''%state%''
                 OR c.name LIKE ''%level%''
                 OR c.name LIKE ''%gender%''
                 OR c.name LIKE ''%priority%''
                 OR c.name LIKE ''%class%''
                 OR c.name LIKE ''%mode%''
                 OR c.name LIKE ''%reason%''
                 OR c.name LIKE ''%result%''
                 OR c.name LIKE ''%enum%''
                 OR (ty.name IN (''char'',''nchar'') AND c.max_length BETWEEN 1 AND 20)
                 OR (ty.name IN (''varchar'',''nvarchar'') AND c.max_length BETWEEN 2 AND 40)
                 OR ty.name IN (''tinyint'',''bit'')
              )
        ),
        CheckCols AS (
            SELECT DISTINCT
                c.object_id,
                c.column_id
            FROM ' + QUOTENAME(@DbName) + N'.sys.check_constraints chk
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.columns c
                ON c.object_id = chk.parent_object_id
            WHERE chk.is_disabled = 0
              AND chk.is_not_trusted = 0
              AND (
                    chk.definition LIKE ''% IN (%''
                 OR chk.definition LIKE ''% in (%''
              )
              AND (
                    CHARINDEX(QUOTENAME(c.name), chk.definition) > 0
                 OR CHARINDEX(c.name, chk.definition) > 0
              )
        ),
        FkCols AS (
            SELECT DISTINCT
                fkc.parent_object_id AS object_id,
                fkc.parent_column_id AS column_id
            FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc
                ON fkc.constraint_object_id = fk.object_id
            WHERE fk.is_disabled = 0
              AND fk.is_not_trusted = 0
        ),
        Scored AS (
            SELECT
                CASE WHEN cc.column_id IS NOT NULL THEN 1 ELSE 0 END AS HasCheck,
                CASE WHEN fk.column_id IS NOT NULL THEN 1 ELSE 0 END AS HasFk
            FROM Cols col
            LEFT JOIN CheckCols cc
                ON cc.object_id = col.object_id AND cc.column_id = col.column_id
            LEFT JOIN FkCols fk
                ON fk.object_id = col.object_id AND fk.column_id = col.column_id
        )
        SELECT
            @pDb,
            COUNT(*),
            ISNULL(SUM(HasCheck), 0),
            ISNULL(SUM(HasFk), 0),
            ISNULL(SUM(CASE WHEN HasCheck = 1 OR HasFk = 1 THEN 1 ELSE 0 END), 0),
            ISNULL(SUM(CASE WHEN HasCheck = 0 AND HasFk = 0 THEN 1 ELSE 0 END), 0)
        FROM Scored;
        ';

        BEGIN TRY
            INSERT INTO @Agg (DatabaseName, CandidateCols, CheckEnforced, FkEnforced, DomainEnforced, Unenforced)
            EXEC sys.sp_executesql
                @Sql,
                N'@pDb NVARCHAR(128)',
                @pDb = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO @Agg (DatabaseName, CandidateCols, CheckEnforced, FkEnforced, DomainEnforced, Unenforced)
            VALUES (@DbName, -1, 0, 0, 0, 0);
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @DatabaseQueried NVARCHAR(128);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @TotCandidates INT = 0;
DECLARE @TotCheck INT = 0;
DECLARE @TotFk INT = 0;
DECLARE @TotDomain INT = 0;
DECLARE @TotUnenforced INT = 0;
DECLARE @DbCount INT = 0;
DECLARE @ErrCount INT = 0;
DECLARE @Pct DECIMAL(5, 2);
DECLARE @DbList NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM @Agg)
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
END
ELSE
BEGIN
    SELECT
        @DbCount = COUNT(*),
        @ErrCount = SUM(CASE WHEN CandidateCols < 0 THEN 1 ELSE 0 END),
        @TotCandidates = SUM(CASE WHEN CandidateCols > 0 THEN CandidateCols ELSE 0 END),
        @TotCheck = SUM(CASE WHEN CandidateCols > 0 THEN CheckEnforced ELSE 0 END),
        @TotFk = SUM(CASE WHEN CandidateCols > 0 THEN FkEnforced ELSE 0 END),
        @TotDomain = SUM(CASE WHEN CandidateCols > 0 THEN DomainEnforced ELSE 0 END),
        @TotUnenforced = SUM(CASE WHEN CandidateCols > 0 THEN Unenforced ELSE 0 END)
    FROM @Agg;

    SELECT @DbList = STUFF((
        SELECT N', ' + DatabaseName
        FROM @Agg
        ORDER BY DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SET @DatabaseQueried = CASE WHEN @DbCount = 1 THEN (SELECT TOP 1 DatabaseName FROM @Agg) ELSE N'ALL' END;

    IF @ErrCount = @DbCount
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Could not read catalog metadata in any accessible database to assess categorical domain enforcement. Databases: ' + ISNULL(@DbList, N'n/a') + N'.';
    END
    ELSE IF @TotCandidates = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No categorical/enum candidate columns were identified by name/type heuristics across ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) (' + ISNULL(@DbList, N'n/a') + N'); no unconstrained domain risk detected from metadata.';
    END
    ELSE
    BEGIN
        SET @Pct = (100.0 * @TotDomain) / NULLIF(@TotCandidates, 0);

        IF @Pct >= 90.0 AND @TotUnenforced = 0
            SET @Score = 3;
        ELSE IF @Pct >= 60.0
            SET @Score = 2;
        ELSE IF @Pct >= 25.0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding =
            N'Across ' + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) (' + ISNULL(@DbList, N'n/a') + N'): categorical candidates=' + CAST(@TotCandidates AS NVARCHAR(20)) +
            N'; CHECK(IN)-enforced=' + CAST(@TotCheck AS NVARCHAR(20)) +
            N'; FK-enforced=' + CAST(@TotFk AS NVARCHAR(20)) +
            N'; domain-enforced=' + CAST(@TotDomain AS NVARCHAR(20)) +
            N'; unenforced=' + CAST(@TotUnenforced AS NVARCHAR(20)) +
            N' (' + CAST(@Pct AS NVARCHAR(20)) + N'% coverage). ' +
            CASE
                WHEN @Score >= 3 THEN N'Domain enforcement via CHECK value lists and/or FKs is strong.'
                WHEN @Score = 2 THEN N'Partial domain enforcement; some categorical columns lack CHECK/FK protection against invalid codes.'
                WHEN @Score = 1 THEN N'Weak domain enforcement; many categorical columns can accept invalid codes.'
                ELSE N'Domain enforcement is essentially absent; invalid categorical codes are largely unconstrained.'
            END;
    END

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
END

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;