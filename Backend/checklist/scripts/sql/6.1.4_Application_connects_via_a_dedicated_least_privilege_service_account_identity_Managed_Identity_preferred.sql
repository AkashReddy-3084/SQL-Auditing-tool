-- Checklist: Application connects via a dedicated least-privilege service account/identity (Managed Identity preferred)
-- Scope: DATABASE
-- Scoring: 3=Managed Identity with least privilege; 2=Dedicated service account with least privilege; 1=Account exists but has elevated roles; 0=No dedicated account or uses sa/dbo/high privileges.

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
    -- Azure SQL Database: Evaluate current connected database only
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';
    DECLARE @HasMI BIT = 0;
    DECLARE @HasDedicated BIT = 0;
    DECLARE @HasHighPriv BIT = 0;
    DECLARE @HighPrivUsers NVARCHAR(MAX) = '';

    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type IN ('X', 'E') AND name NOT IN ('dbo', 'guest'))
        SET @HasMI = 1;

    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type IN ('S', 'U', 'G') AND name NOT IN ('dbo', 'guest'))
        SET @HasDedicated = 1;

    SELECT @HighPrivUsers = STRING_AGG(dp.name, ', ')
    FROM sys.database_principals dp
    JOIN sys.database_role_members drm ON dp.principal_id = drm.member_principal_id
    JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id
    WHERE dr.name IN ('db_owner', 'db_ddladmin', 'db_securityadmin', 'db_accessadmin')
      AND dp.name NOT IN ('dbo', 'guest');

    IF @HighPrivUsers IS NOT NULL SET @HasHighPriv = 1;

    IF @HasMI = 1 AND @HasHighPriv = 0
        SET @DbScore = 3;
    ELSE IF @HasDedicated = 1 AND @HasHighPriv = 0
        SET @DbScore = 2;
    ELSE IF @HasDedicated = 1 AND @HasHighPriv = 1
        SET @DbScore = 1;
    ELSE
        SET @DbScore = 0;

    IF @DbScore = 3
        SET @DbFinding = 'Managed Identity user(s) found with least privilege.';
    ELSE IF @DbScore = 2
        SET @DbFinding = 'Dedicated service account(s) found with least privilege. Managed Identity not used.';
    ELSE IF @DbScore = 1
        SET @DbFinding = 'Account(s) found with elevated privileges: ' + @HighPrivUsers;
    ELSE
        SET @DbFinding = 'No dedicated service account or Managed Identity identified. Default accounts or high privileges detected.';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (DB_NAME(), @DbScore, @DbFinding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
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
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '''';
            DECLARE @HasMI BIT = 0;
            DECLARE @HasDedicated BIT = 0;
            DECLARE @HasHighPriv BIT = 0;
            DECLARE @HighPrivUsers NVARCHAR(MAX) = '''';

            IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type IN (''X'', ''E'') AND name NOT IN (''dbo'', ''guest''))
                SET @HasMI = 1;

            IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type IN (''S'', ''U'', ''G'') AND name NOT IN (''dbo'', ''guest''))
                SET @HasDedicated = 1;

            SELECT @HighPrivUsers = STRING_AGG(dp.name, '','')
            FROM sys.database_principals dp
            JOIN sys.database_role_members drm ON dp.principal_id = drm.member_principal_id
            JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id
            WHERE dr.name IN (''db_owner'', ''db_ddladmin'', ''db_securityadmin'', ''db_accessadmin'')
              AND dp.name NOT IN (''dbo'', ''guest'');

            IF @HighPrivUsers IS NOT NULL SET @HasHighPriv = 1;

            IF @HasMI = 1 AND @HasHighPriv = 0
                SET @DbScore = 3;
            ELSE IF @HasDedicated = 1 AND @HasHighPriv = 0
                SET @DbScore = 2;
            ELSE IF @HasDedicated = 1 AND @HasHighPriv = 1
                SET @DbScore = 1;
            ELSE
                SET @DbScore = 0;

            IF @DbScore = 3
                SET @DbFinding = ''Managed Identity user(s) found with least privilege.'';
            ELSE IF @DbScore = 2
                SET @DbFinding = ''Dedicated service account(s) found with least privilege. Managed Identity not used.'';
            ELSE IF @DbScore = 1
                SET @DbFinding = ''Account(s) found with elevated privileges: '' + @HighPrivUsers;
            ELSE
                SET @DbFinding = ''No dedicated service account or Managed Identity identified. Default accounts or high privileges detected.'';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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