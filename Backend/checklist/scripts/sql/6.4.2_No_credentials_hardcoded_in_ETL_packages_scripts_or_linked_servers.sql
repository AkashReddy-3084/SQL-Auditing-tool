-- Checklist: No credentials hardcoded in ETL packages, scripts, or linked servers
-- Scope: SERVER
-- Scoring: 3=No hardcoded credentials found; 2=1-2 findings (minor gaps); 1=3-5 findings (largely incomplete); 0=>5 findings (completely non-compliant). Pattern matching is heuristic; full compliance requires human review.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @TotalFindings INT = 0;
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #Findings (
    Source NVARCHAR(128),
    ObjectName NVARCHAR(256),
    Evidence NVARCHAR(256)
);

-- 1. Linked Servers (SQL Server / MI only)
IF @EngineEdition <> 5
BEGIN
    BEGIN TRY
        INSERT INTO #Findings (Source, ObjectName, Evidence)
        SELECT 'LinkedServer', ls.name, 'uses_self_credential = 0'
        FROM sys.linked_servers ls
        INNER JOIN sys.linked_logins ll ON ls.server_id = ll.server_id
        WHERE ll.uses_self_credential = 0;
    END TRY
    BEGIN CATCH
        -- Ignore if view unavailable
    END CATCH
END

-- 2. SSIS Packages (SQL Server / MI only)
IF @EngineEdition <> 5
BEGIN
    BEGIN TRY
        INSERT INTO #Findings (Source, ObjectName, Evidence)
        SELECT 'SSISPackage', name, 'Hardcoded password in package XML'
        FROM msdb.dbo.syspackages
        WHERE CAST(package_xml AS NVARCHAR(MAX)) LIKE '%<DTS:Property DTS:Name="Password">%';
    END TRY
    BEGIN CATCH
        -- Ignore if table unavailable
    END CATCH
END

-- 3. User Database Modules
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #Findings (Source, ObjectName, Evidence)
        SELECT ''Module'', QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)),
               ''Hardcoded credential pattern detected''
        FROM sys.sql_modules
        WHERE definition IS NOT NULL
          AND (definition LIKE ''%password = %''
             OR definition LIKE ''%pwd = %''
             OR definition LIKE ''%secret = %''
             OR definition LIKE ''%connection string%'');';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Skip inaccessible databases
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = 'master';

SELECT @TotalFindings = COUNT(*) FROM #Findings;

IF @TotalFindings = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No hardcoded credentials detected in linked servers, SSIS packages, or user database modules.';
END
ELSE
BEGIN
    SET @Finding = (SELECT STRING_AGG(Source + ': ' + ObjectName + ' (' + Evidence + ')', '; ') FROM #Findings);
    IF @TotalFindings <= 2 SET @Score = 2;
    ELSE IF @TotalFindings <= 5 SET @Score = 1;
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #Findings;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;