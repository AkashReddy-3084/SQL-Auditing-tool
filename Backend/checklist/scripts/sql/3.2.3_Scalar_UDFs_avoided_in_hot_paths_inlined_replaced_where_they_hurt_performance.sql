-- Checklist: Scalar UDFs avoided in hot paths (inlined/replaced where they hurt performance)
-- Scope: DATABASE
-- Scoring: 3: No scalar UDFs exist. 2: Scalar UDFs exist but are not referenced by other objects. 1: Scalar UDFs exist and have <= 5 references. 0: Scalar UDFs exist and have > 5 references.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @IsAzureSQL BIT = CASE WHEN SERVERPROPERTY('EngineEdition') = 5 THEN 1 ELSE 0 END;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQL = 1
BEGIN
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'
        DECLARE @UdfCount INT = 0;
        DECLARE @RefCount INT = 0;
        DECLARE @DbScore INT;
        DECLARE @Finding NVARCHAR(MAX);

        SELECT @UdfCount = COUNT(*) FROM sys.objects WHERE type = ''FN'';

        IF @UdfCount > 0
        BEGIN
            SELECT @RefCount = COUNT(DISTINCT referencing_id)
            FROM sys.sql_expression_dependencies
            WHERE referencing_id > 0
              AND referenced_id IN (SELECT object_id FROM sys.objects WHERE type = ''FN'');
        END

        IF @UdfCount = 0 SET @DbScore = 3;
        ELSE IF @RefCount = 0 SET @DbScore = 2;
        ELSE IF @RefCount <= 5 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        IF @UdfCount = 0 SET @Finding = ''No scalar UDFs found'';
        ELSE IF @RefCount = 0 SET @Finding = CAST(@UdfCount AS NVARCHAR) + '' scalar UDF(s) found, but none are referenced'';
        ELSE SET @Finding = CAST(@UdfCount AS NVARCHAR) + '' scalar UDF(s) found with '' + CAST(@RefCount AS NVARCHAR) + '' reference(s)'';

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @Finding);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @UdfCount INT = 0;
            DECLARE @RefCount INT = 0;
            DECLARE @DbScore INT;
            DECLARE @Finding NVARCHAR(MAX);

            SELECT @UdfCount = COUNT(*) FROM sys.objects WHERE type = ''FN'';

            IF @UdfCount > 0
            BEGIN
                SELECT @RefCount = COUNT(DISTINCT referencing_id)
                FROM sys.sql_expression_dependencies
                WHERE referencing_id > 0
                  AND referenced_id IN (SELECT object_id FROM sys.objects WHERE type = ''FN'');
            END

            IF @UdfCount = 0 SET @DbScore = 3;
            ELSE IF @RefCount = 0 SET @DbScore = 2;
            ELSE IF @RefCount <= 5 SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            IF @UdfCount = 0 SET @Finding = ''No scalar UDFs found'';
            ELSE IF @RefCount = 0 SET @Finding = CAST(@UdfCount AS NVARCHAR) + '' scalar UDF(s) found, but none are referenced'';
            ELSE SET @Finding = CAST(@UdfCount AS NVARCHAR) + '' scalar UDF(s) found with '' + CAST(@RefCount AS NVARCHAR) + '' reference(s)'';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @Finding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;