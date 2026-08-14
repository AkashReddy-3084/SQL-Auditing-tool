-- Checklist: Data validation tests run post-deployment (counts, schema checks)
-- Scope: DATABASE
-- Scoring: 
-- 3 = Found procedure named 'Validate'/'PostDeploy' AND body contains 'COUNT'/'Schema' (Strong evidence of automated validation)
-- 2 = Found procedure named 'Validate'/'PostDeploy' OR body contains 'COUNT'/'Schema' (Partial evidence)
-- 1 = Found procedure named 'Test'/'Check' (Weak evidence)
-- 0 = No evidence found

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

-- Create temp table to collect per-database results
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DbScore = 0;

    BEGIN TRY
        -- Check for validation procedures
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @DbScore = CASE 
            -- Score 3: Name implies validation/deployment AND body implies counts/schema checks
            WHEN EXISTS (
                SELECT 1 FROM sys.procedures p
                JOIN sys.sql_modules m ON p.object_id = m.object_id
                WHERE (p.name LIKE ''%Validate%'' OR p.name LIKE ''%PostDeploy%'' OR p.name LIKE ''%Post_Deploy%'')
                AND (m.definition LIKE ''%COUNT%'' OR m.definition LIKE ''%INFORMATION_SCHEMA%'' OR m.definition LIKE ''%sys.columns%'' OR m.definition LIKE ''%sys.tables%'')
            ) THEN 3
            
            -- Score 2: Name implies validation/deployment OR body implies counts/schema checks
            WHEN EXISTS (
                SELECT 1 FROM sys.procedures p
                JOIN sys.sql_modules m ON p.object_id = m.object_id
                WHERE (p.name LIKE ''%Validate%'' OR p.name LIKE ''%PostDeploy%'' OR p.name LIKE ''%Post_Deploy%'')
                OR (m.definition LIKE ''%COUNT%'' OR m.definition LIKE ''%INFORMATION_SCHEMA%'' OR m.definition LIKE ''%sys.columns%'' OR m.definition LIKE ''%sys.tables%'')
            ) THEN 2

            -- Score 1: Name implies generic testing
            WHEN EXISTS (
                SELECT 1 FROM sys.procedures p
                WHERE p.name LIKE ''%Test%'' OR p.name LIKE ''%Check%''
            ) THEN 1

            ELSE 0
        END;
        ';
        
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
    END TRY
    BEGIN CATCH
        SET @DbScore = 0;
    END CATCH;

    INSERT INTO #DbResults VALUES (@DbName, @DbScore);

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;