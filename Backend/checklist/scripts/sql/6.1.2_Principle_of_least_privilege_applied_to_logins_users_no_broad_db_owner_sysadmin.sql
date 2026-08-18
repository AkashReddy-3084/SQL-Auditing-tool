-- Checklist: Principle of least privilege applied to logins/users (no broad db_owner/sysadmin)
-- Scope: DATABASE
-- Scoring: 3=0 members, 2=1-2 members, 1=3-5 members, 0=>5 members

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @TotalCount INT = 0;
DECLARE @AllNames NVARCHAR(MAX) = '';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbCount INT;
DECLARE @DbNames NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

-- Check server-level sysadmin (SQL Server / MI only)
IF SERVERPROPERTY('EngineEdition') <> 5
BEGIN
    SELECT @TotalCount = COUNT(*), @AllNames = STRING_AGG(name, ', ')
    FROM master.sys.server_role_members srm
    JOIN master.sys.server_principals sp ON srm.member_principal_id = sp.principal_id
    JOIN master.sys.server_principals srp ON srm.role_principal_id = srp.principal_id
    WHERE srp.name = 'sysadmin';

    IF @TotalCount > 0
        SET @AllNames = 'Server: ' + @AllNames;
END

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DbCount = 0;
    SET @DbNames = '';

    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @DbCountOut = COUNT(*), @DbNamesOut = STRING_AGG(dp.name, '','')
        FROM sys.database_role_members drm
        JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
        JOIN sys.database_principals drp ON drm.role_principal_id = drp.principal_id
        WHERE drp.name = ''db_owner'';';

        EXEC sp_executesql @Sql,
            N'@DbCountOut INT OUTPUT, @DbNamesOut NVARCHAR(MAX) OUTPUT',
            @DbCountOut = @DbCount OUTPUT,
            @DbNamesOut = @DbNames OUTPUT;

        IF @DbCount > 0
        BEGIN
            SET @TotalCount = @TotalCount + @DbCount;
            SET @AllNames = @AllNames + CASE WHEN @AllNames <> '' THEN '; ' ELSE '' END + @DbName + ': ' + @DbNames;
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 3, CASE WHEN @DbCount = 0 THEN 'No db_owner users' ELSE CAST(@DbCount AS NVARCHAR(10)) + ' db_owner users: ' + @DbNames END);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = CASE
    WHEN @TotalCount = 0 THEN 3
    WHEN @TotalCount <= 2 THEN 2
    WHEN @TotalCount <= 5 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @TotalCount = 0 THEN 'No broad privileges (sysadmin/db_owner) found.'
    ELSE 'Found ' + CAST(@TotalCount AS NVARCHAR(10)) + ' members with broad privileges: ' + @AllNames
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;