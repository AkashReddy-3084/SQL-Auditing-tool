-- Checklist: String / Text: encoding/collation consistent; max length respected; no silent truncation
-- Scope: DATABASE
-- Scoring: 3=Fully compliant (ANSI_PADDING ON, 100% collation match, no fixed-length strings, no zero-length columns); 2=Minor gaps (ANSI_PADDING ON, <5% collation mismatch or fixed-length strings present); 1=Significant gaps (ANSI_PADDING OFF, zero-length columns, or >5% mismatch); 0=No string columns or severe misconfiguration
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DbScore INT = 0;
        DECLARE @DbCollation NVARCHAR(128) = DATABASEPROPERTYEX(DB_NAME(), ''Collation'');
        DECLARE @AnsiPadding INT = DATABASEPROPERTYEX(DB_NAME(), ''IsAnsiPadding'');
        DECLARE @TotalStrings INT = 0;
        DECLARE @MismatchedCollation INT = 0;
        DECLARE @FixedLengthStrings INT = 0;
        DECLARE @ZeroLengthStrings INT = 0;

        SELECT @TotalStrings = COUNT(*),
               @MismatchedCollation = SUM(CASE WHEN c.collation_name <> @DbCollation THEN 1 ELSE 0 END),
               @FixedLengthStrings = SUM(CASE WHEN t.name IN (''char'', ''nchar'') THEN 1 ELSE 0 END),
               @ZeroLengthStrings = SUM(CASE WHEN c.max_length = 0 THEN 1 ELSE 0 END)
        FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        JOIN sys.tables tbl ON c.object_id = tbl.object_id
        WHERE t.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'');

        IF @TotalStrings = 0 SET @DbScore = 3;
        ELSE BEGIN
            IF @AnsiPadding = 0 OR @ZeroLengthStrings > 0 SET @DbScore = 1;
            ELSE BEGIN
                IF @MismatchedCollation = 0 AND @FixedLengthStrings = 0 SET @DbScore = 3;
                ELSE IF @MismatchedCollation = 0 SET @DbScore = 2;
                ELSE IF CAST(@MismatchedCollation AS FLOAT) / @TotalStrings < 0.05 SET @DbScore = 2;
                ELSE SET @DbScore = 1;
            END
        END
        SELECT @DbScore;';
        INSERT INTO #DbResults
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;