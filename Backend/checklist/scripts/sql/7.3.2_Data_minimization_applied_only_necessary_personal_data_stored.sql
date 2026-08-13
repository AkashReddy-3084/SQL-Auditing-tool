-- Checklist: Data minimization applied — only necessary personal data stored
-- Scope: DATABASE
-- Scoring: 0=Fail (error/no access), 1=Partial Pass (PII found, untagged), 2=Mostly Pass (PII found, tagged/classified), 3=Pass (No PII found)
SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Create temp table to collect per-database results
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Safely escape single quotes in database name for string literal embedding
        DECLARE @SafeDbName NVARCHAR(256) = REPLACE(@DbName, '''', '''''');
        
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @HasPII BIT = 0;
        DECLARE @HasClassification BIT = 0;
        DECLARE @DbScore INT = 3;

        IF EXISTS (
            SELECT 1 FROM sys.columns c
            JOIN sys.types t ON c.user_type_id = t.user_type_id
            WHERE t.name IN (''nvarchar'', ''varchar'', ''nchar'', ''char'')
            AND (
                c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%ssn%'' OR
                c.name LIKE ''%passport%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%birth%'' OR
                c.name LIKE ''%address%'' OR c.name LIKE ''%credit_card%'' OR c.name LIKE ''%tax_id%'' OR
                c.name LIKE ''%mobile%'' OR c.name LIKE ''%ip_address%'' OR c.name LIKE ''%mac_address%''
            )
        ) SET @HasPII = 1;

        IF @HasPII = 1
        BEGIN
            IF EXISTS (
                SELECT 1 FROM sys.extended_properties ep
                JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
                WHERE ep.name IN (''DataClassification'', ''SensitivityLabel'', ''MS_Description'')
                AND (
                    c.name LIKE ''%email%'' OR c.name LIKE ''%phone%'' OR c.name LIKE ''%ssn%'' OR
                    c.name LIKE ''%passport%'' OR c.name LIKE ''%dob%'' OR c.name LIKE ''%birth%'' OR
                    c.name LIKE ''%address%'' OR c.name LIKE ''%credit_card%'' OR c.name LIKE ''%tax_id%'' OR
                    c.name LIKE ''%mobile%'' OR c.name LIKE ''%ip_address%'' OR c.name LIKE ''%mac_address%''
                )
            ) SET @HasClassification = 1;
        END

        IF @HasPII = 0 SET @DbScore = 3;
        ELSE IF @HasClassification = 1 SET @DbScore = 2;
        ELSE SET @DbScore = 1;

        INSERT INTO #DbResults VALUES (''' + @SafeDbName + ''', @DbScore);';
        EXEC sp_executesql @Sql;
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