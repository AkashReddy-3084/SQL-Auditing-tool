-- Checklist: Sensitive data: masked/protected where required; format validation applied
-- Scope: DATABASE
-- Scoring: 0=No masking/constraints found; 1=<30% sensitive columns protected; 2=30-80% protected; 3=>80% protected or no sensitive columns

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
        DECLARE @TotalSensitive INT = 0;
        DECLARE @Protected INT = 0;
        DECLARE @UnprotectedList NVARCHAR(MAX) = '';

        WITH SensitiveCols AS (
            SELECT 
                t.name AS TableName,
                c.name AS ColumnName,
                CASE WHEN mc.masking_function IS NOT NULL THEN 1 ELSE 0 END AS IsMasked,
                CASE WHEN cc.name IS NOT NULL THEN 1 ELSE 0 END AS HasConstraint
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            LEFT JOIN sys.masked_columns mc ON c.object_id = mc.object_id AND c.column_id = mc.column_id
            LEFT JOIN sys.check_constraints cc ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
            WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%social_security%'' OR c.name LIKE ''%credit_card%'' 
              OR c.name LIKE ''%cc_num%'' OR c.name LIKE ''%password%'' OR c.name LIKE ''%pwd%'' 
              OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%mobile%'' 
              OR c.name LIKE ''%address%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%date_of_birth%'' 
              OR c.name LIKE ''%salary%'' OR c.name LIKE ''%income%'' OR c.name LIKE ''%bank_account%'' 
              OR c.name LIKE ''%routing_num%''
        )
        SELECT 
            @TotalSensitive = COUNT(*),
            @Protected = SUM(CASE WHEN IsMasked = 1 OR HasConstraint = 1 THEN 1 ELSE 0 END),
            @UnprotectedList = STRING_AGG(TableName + ''.'' + ColumnName, '', '') WITHIN GROUP (ORDER BY TableName, ColumnName)
        FROM SensitiveCols
        WHERE IsMasked = 0 AND HasConstraint = 0;

        DECLARE @HasAnyProtection INT = 0;
        SELECT @HasAnyProtection = CASE WHEN EXISTS (SELECT 1 FROM sys.masked_columns) OR EXISTS (SELECT 1 FROM sys.check_constraints) THEN 1 ELSE 0 END;

        DECLARE @DbScore INT = 0;
        DECLARE @Finding NVARCHAR(MAX) = '';

        IF @TotalSensitive = 0
        BEGIN
            SET @DbScore = 3;
            SET @Finding = ''No sensitive columns identified. Database appears compliant.'';
        END
        ELSE IF @HasAnyProtection = 0
        BEGIN
            SET @DbScore = 0;
            SET @Finding = ''No masking or format validation found. Sensitive columns: '' + @UnprotectedList;
        END
        ELSE
        BEGIN
            DECLARE @Pct FLOAT = CAST(@Protected AS FLOAT) / @TotalSensitive * 100;
            IF @Pct >= 80
            BEGIN
                SET @DbScore = 3;
                SET @Finding = ''Sensitive columns: '' + CAST(@TotalSensitive AS NVARCHAR(10)) + ''. Protected: '' + CAST(@Protected AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(10)) + ''%).'';
            END
            ELSE IF @Pct >= 30
            BEGIN
                SET @DbScore = 2;
                SET @Finding = ''Sensitive columns: '' + CAST(@TotalSensitive AS NVARCHAR(10)) + ''. Protected: '' + CAST(@Protected AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(10)) + ''%). Unprotected: '' + @UnprotectedList;
            END
            ELSE
            BEGIN
                SET @DbScore = 1;
                SET @Finding = ''Sensitive columns: '' + CAST(@TotalSensitive AS NVARCHAR(10)) + ''. Protected: '' + CAST(@Protected AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(10)) + ''%). Unprotected: '' + @UnprotectedList;
            END
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', @DbScore, @Finding);
        ';

        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed: ' + ERROR_MESSAGE());
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

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