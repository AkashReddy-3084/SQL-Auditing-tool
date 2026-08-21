-- Checklist: Data validation tests run post-deployment (counts, schema checks)
-- Scope: SERVER
-- Scoring: 3: >=3 validation objects/jobs found explicitly for post-deployment. 2: 1-2 validation objects found. 1: 0 validation objects but generic test objects exist. 0: No validation or test objects found.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #ValidationEvidence (
    DbName NVARCHAR(128),
    ObjectName NVARCHAR(256),
    ObjectType NVARCHAR(20),
    Evidence NVARCHAR(MAX)
);

IF @EngineEdition <> 5
BEGIN
    -- SQL Server / Azure SQL MI: Check all user databases and msdb
    DECLARE @DbName NVARCHAR(128);
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #ValidationEvidence (DbName, ObjectName, ObjectType, Evidence)
        SELECT ''' + @DbName + N''', name, type_desc, 
               CASE 
                   WHEN name LIKE ''%Validate%'' OR name LIKE ''%Validation%'' OR name LIKE ''%Count%'' OR name LIKE ''%SchemaCheck%'' THEN ''Name indicates validation purpose''
                   ELSE ''Definition contains validation keywords''
               END
        FROM sys.procedures
        WHERE name LIKE ''%Validate%'' OR name LIKE ''%Validation%'' OR name LIKE ''%Count%'' OR name LIKE ''%SchemaCheck%''
           OR OBJECT_DEFINITION(object_id) LIKE ''%row count%'' OR OBJECT_DEFINITION(object_id) LIKE ''%schema check%'' OR OBJECT_DEFINITION(object_id) LIKE ''%validation%'' OR OBJECT_DEFINITION(object_id) LIKE ''%post-deploy%'';';
        
        BEGIN TRY
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            -- Ignore inaccessible databases
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- Check msdb for validation/deployment jobs
    INSERT INTO #ValidationEvidence (DbName, ObjectName, ObjectType, Evidence)
    SELECT 'msdb', name, 'Job', 'Job name/description indicates validation or post-deployment execution'
    FROM msdb.dbo.sysjobs
    WHERE name LIKE '%Validate%' OR name LIKE '%Validation%' OR name LIKE '%Post-Deploy%' OR name LIKE '%PostDeploy%'
       OR description LIKE '%validation%' OR description LIKE '%post-deployment%';
END
ELSE
BEGIN
    -- Azure SQL Database: Check current database only
    INSERT INTO #ValidationEvidence (DbName, ObjectName, ObjectType, Evidence)
    SELECT DB_NAME(), name, type_desc, 
           CASE 
               WHEN name LIKE '%Validate%' OR name LIKE '%Validation%' OR name LIKE '%Count%' OR name LIKE '%SchemaCheck%' THEN 'Name indicates validation purpose'
               ELSE 'Definition contains validation keywords'
           END
    FROM sys.procedures
    WHERE name LIKE '%Validate%' OR name LIKE '%Validation%' OR name LIKE '%Count%' OR name LIKE '%SchemaCheck%'
       OR OBJECT_DEFINITION(object_id) LIKE '%row count%' OR OBJECT_DEFINITION(object_id) LIKE '%schema check%' OR OBJECT_DEFINITION(object_id) LIKE '%validation%' OR OBJECT_DEFINITION(object_id) LIKE '%post-deploy%';
END

-- Aggregate results
SET @DatabaseQueried = 'master';

DECLARE @TotalObjects INT = (SELECT COUNT(*) FROM #ValidationEvidence);
DECLARE @ValidationObjects INT = (SELECT COUNT(*) FROM #ValidationEvidence WHERE Evidence LIKE '%validation%' OR Evidence LIKE '%Validate%');

IF @TotalObjects >= 3 OR @ValidationObjects >= 2
BEGIN
    SET @Score = 3;
    SET @Finding = 'Found ' + CAST(@TotalObjects AS NVARCHAR) + ' validation/test objects across databases and jobs. Evidence: ' + 
        ISNULL((SELECT STRING_AGG(ObjectName, ', ') FROM #ValidationEvidence), 'None');
END
ELSE IF @TotalObjects >= 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Found ' + CAST(@TotalObjects AS NVARCHAR) + ' potential validation/test objects. Evidence: ' + 
        ISNULL((SELECT STRING_AGG(ObjectName, ', ') FROM #ValidationEvidence), 'None');
END
ELSE IF EXISTS (SELECT 1 FROM sys.procedures WHERE name LIKE '%Test%')
BEGIN
    SET @Score = 1;
    SET @Finding = 'No explicit validation objects found. Found generic test objects in current database.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No data validation procedures, jobs, or scripts found.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #ValidationEvidence;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;