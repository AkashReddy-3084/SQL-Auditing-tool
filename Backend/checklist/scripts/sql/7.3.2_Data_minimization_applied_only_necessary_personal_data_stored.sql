-- Checklist: Data minimization applied — only necessary personal data stored
-- Scope: DATABASE
-- Scoring: 0: No personal data columns or classification metadata found (verification impossible). 1: Personal data columns identified via naming patterns, but lack formal classification. 2: Personal data columns identified and formally classified, enabling human review for necessity. 3: Not achievable automatically (requires business context).

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

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

IF @IsAzureSQLDB = 1
BEGIN
    SET @Sql = N'DECLARE @PiiList NVARCHAR(MAX) = (
        SELECT STRING_AGG(t.name + ''.'' + c.name, '', '')
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%address%'' OR c.name LIKE ''%pii%'' OR c.name LIKE ''%personal%'' OR c.name LIKE ''%credit%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%nationalid%''
    );
    DECLARE @ClassifiedCount INT = (
        SELECT COUNT(*) FROM sys.extended_properties ep
        JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
        WHERE ep.name = ''Microsoft Information Classification''
    );
    DECLARE @PiiCount INT = ISNULL((SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%address%'' OR c.name LIKE ''%pii%'' OR c.name LIKE ''%personal%'' OR c.name LIKE ''%credit%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%nationalid%''), 0);

    SELECT DB_NAME() AS DbName,
        CASE
            WHEN @PiiCount = 0 AND @ClassifiedCount = 0 THEN 0
            WHEN @PiiCount > 0 AND @ClassifiedCount = 0 THEN 1
            ELSE 2
        END AS DbScore,
        CASE
            WHEN @PiiCount = 0 AND @ClassifiedCount = 0 THEN ''No personal data columns or classification metadata found''
            WHEN @PiiCount > 0 AND @ClassifiedCount = 0 THEN ''Personal data columns identified by name: '' + ISNULL(@PiiList, ''None'')
            ELSE ''Personal data columns identified and classified: '' + ISNULL(@PiiList, ''None'')
        END AS DbFinding;';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC(@Sql);
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
            DECLARE @PiiList NVARCHAR(MAX) = (
                SELECT STRING_AGG(t.name + ''.'' + c.name, '', '')
                FROM sys.columns c
                JOIN sys.tables t ON c.object_id = t.object_id
                WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%address%'' OR c.name LIKE ''%pii%'' OR c.name LIKE ''%personal%'' OR c.name LIKE ''%credit%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%nationalid%''
            );
            DECLARE @ClassifiedCount INT = (
                SELECT COUNT(*) FROM sys.extended_properties ep
                JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
                WHERE ep.name = ''Microsoft Information Classification''
            );
            DECLARE @PiiCount INT = ISNULL((SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%address%'' OR c.name LIKE ''%pii%'' OR c.name LIKE ''%personal%'' OR c.name LIKE ''%credit%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%nationalid%''), 0);

            SELECT ''' + @DbName + ''' AS DbName,
                CASE
                    WHEN @PiiCount = 0 AND @ClassifiedCount = 0 THEN 0
                    WHEN @PiiCount > 0 AND @ClassifiedCount = 0 THEN 1
                    ELSE 2
                END AS DbScore,
                CASE
                    WHEN @PiiCount = 0 AND @ClassifiedCount = 0 THEN ''No personal data columns or classification metadata found''
                    WHEN @PiiCount > 0 AND @ClassifiedCount = 0 THEN ''Personal data columns identified by name: '' + ISNULL(@PiiList, ''None'')
                    ELSE ''Personal data columns identified and classified: '' + ISNULL(@PiiList, ''None'')
                END AS DbFinding;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC(@Sql);
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

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Finding = @Finding + CHAR(13) + CHAR(10) + '-- NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;