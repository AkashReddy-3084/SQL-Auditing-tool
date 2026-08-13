-- Checklist: Non-prod environments scaled down / paused when idle
-- Scope: DATABASE
-- Scoring: 3=Compliant (active or paused/idle), 2=Mostly compliant (idle but on-prem where pause isn't native), 1=Non-compliant (idle and not paused/scaled down), 0=No non-prod DBs or all non-compliant
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Create temp table to collect per-database results, including non-prod flag
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT, IsNonProd BIT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @IsNonProd BIT = 0;
        DECLARE @ActiveRequests INT = 0;
        DECLARE @StateDesc NVARCHAR(60) = '''';
        DECLARE @DbScore INT = 3;
        DECLARE @EngineEdition INT = CAST(SERVERPROPERTY(''EngineEdition'') AS INT);

        IF LOWER(DB_NAME()) LIKE ''%dev%'' OR LOWER(DB_NAME()) LIKE ''%test%'' OR LOWER(DB_NAME()) LIKE ''%qa%'' OR LOWER(DB_NAME()) LIKE ''%staging%'' OR LOWER(DB_NAME()) LIKE ''%uat%'' OR LOWER(DB_NAME()) LIKE ''%sandbox%''
            SET @IsNonProd = 1;

        SELECT @ActiveRequests = COUNT(*) FROM sys.dm_exec_requests WHERE database_id = DB_ID();

        SELECT @StateDesc = state_desc FROM sys.databases WHERE database_id = DB_ID();

        IF @IsNonProd = 1
        BEGIN
            IF @ActiveRequests = 0
            BEGIN
                IF @StateDesc = ''PAUSED''
                    SET @DbScore = 3;
                ELSE IF @EngineEdition IN (1, 2, 3, 4)
                    SET @DbScore = 2;
                ELSE
                    SET @DbScore = 1;
            END
            ELSE
            BEGIN
                SET @DbScore = 3;
            END
        END

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @IsNonProd);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Check if any non-prod databases were found
DECLARE @NonProdCount INT = (SELECT COUNT(*) FROM #DbResults WHERE IsNonProd = 1);

IF @NonProdCount = 0
BEGIN
    -- Checklist specifies 0 when no non-prod DBs exist
    SET @Score = 0;
END
ELSE
BEGIN
    -- Worst-case score across all identified non-prod databases
    SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults WHERE IsNonProd = 1), 0);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;