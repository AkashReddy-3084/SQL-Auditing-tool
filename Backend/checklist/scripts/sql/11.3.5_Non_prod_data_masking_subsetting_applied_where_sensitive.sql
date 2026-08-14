-- Checklist: Non-prod data masking/subsetting applied where sensitive
-- Scope: DATABASE
-- Scoring: 0=Prod env or no masking; 1=<30% masked; 2=30-79% masked; 3=>=80% masked. Uses integer multiplication for thresholds.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Detect production environment
        DECLARE @IsProd BIT = 0;
        IF UPPER(@@SERVERNAME) LIKE '%PROD%' OR UPPER(@DbName) LIKE '%PROD%' SET @IsProd = 1;

        IF @IsProd = 1
        BEGIN
            INSERT INTO #DbResults VALUES (@DbName, 0);
        END
        ELSE
        BEGIN
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SET NOCOUNT ON;
            DECLARE @TotalSensitive INT = 0;
            DECLARE @MaskedSensitive INT = 0;

            -- Count sensitive columns based on naming patterns
            SELECT @TotalSensitive = COUNT(*)
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%social%'' OR c.name LIKE ''%credit%''
               OR c.name LIKE ''%card%'' OR c.name LIKE ''%cvv%'' OR c.name LIKE ''%pin%''
               OR c.name LIKE ''%password%'' OR c.name LIKE ''%pwd%'' OR c.name LIKE ''%secret%''
               OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%mobile%''
               OR c.name LIKE ''%address%'' OR c.name LIKE ''%salary%'' OR c.name LIKE ''%income%''
               OR c.name LIKE ''%tax%'' OR c.name LIKE ''%bank%'' OR c.name LIKE ''%account%'';

            -- Count masked sensitive columns (check view existence for compatibility)
            IF OBJECT_ID(''sys.masked_columns'') IS NOT NULL
            BEGIN
                SELECT @MaskedSensitive = COUNT(*)
                FROM sys.masked_columns mc
                JOIN sys.columns c ON mc.object_id = c.object_id AND mc.column_id = c.column_id
                JOIN sys.tables t ON c.object_id = t.object_id
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE c.name LIKE ''%ssn%'' OR c.name LIKE ''%social%'' OR c.name LIKE ''%credit%''
                   OR c.name LIKE ''%card%'' OR c.name LIKE ''%cvv%'' OR c.name LIKE ''%pin%''
                   OR c.name LIKE ''%password%'' OR c.name LIKE ''%pwd%'' OR c.name LIKE ''%secret%''
                   OR c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%mobile%''
                   OR c.name LIKE ''%address%'' OR c.name LIKE ''%salary%'' OR c.name LIKE ''%income%''
                   OR c.name LIKE ''%tax%'' OR c.name LIKE ''%bank%'' OR c.name LIKE ''%account%'';
            END

            -- Determine score using integer multiplication to avoid truncation errors
            IF @TotalSensitive = 0
            BEGIN
                INSERT INTO #DbResults VALUES (''' + @DbName + ''', 2);
            END
            ELSE IF @MaskedSensitive * 100 >= @TotalSensitive * 80
            BEGIN
                INSERT INTO #DbResults VALUES (''' + @DbName + ''', 3);
            END
            ELSE IF @MaskedSensitive * 100 >= @TotalSensitive * 30
            BEGIN
                INSERT INTO #DbResults VALUES (''' + @DbName + ''', 2);
            END
            ELSE
            BEGIN
                INSERT INTO #DbResults VALUES (''' + @DbName + ''', 1);
            END
            ';
            EXEC sp_executesql @Sql;
        END
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.