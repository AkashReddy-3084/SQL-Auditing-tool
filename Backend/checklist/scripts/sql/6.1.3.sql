-- Checklist: Database roles used for permission grants (not per-user grants)
-- Scope: DATABASE
-- Scoring: 3 = no direct user grants; 2 = < 5% direct; 1 = 5-25% direct; 0 = > 25% direct

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN CAST(SUM(CASE WHEN dp.type <> 'R' THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) < 0.05 THEN 2
            WHEN CAST(SUM(CASE WHEN dp.type <> 'R' THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) < 0.25 THEN 1
            ELSE 0 
        END,
        (SELECT ISNULL(STRING_AGG(QUOTENAME(dp2.name), ', '), 'None')
         FROM sys.database_permissions p2
         JOIN sys.database_principals dp2 ON p2.grantee_principal_id = dp2.principal_id
         WHERE dp2.type <> 'R' AND dp2.name NOT IN ('dbo', 'sys', 'INFORMATION_SCHEMA'))
    FROM sys.database_permissions p
    JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
    WHERE dp.name NOT IN ('dbo', 'sys', 'INFORMATION_SCHEMA');
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT 
                @p_Db,
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN CAST(SUM(CASE WHEN dp.type <> ''R'' THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) < 0.05 THEN 2
                    WHEN CAST(SUM(CASE WHEN dp.type <> ''R'' THEN 1 ELSE 0 END) AS FLOAT) / NULLIF(COUNT(*), 0) < 0.25 THEN 1
                    ELSE 0 
                END,
                (SELECT ISNULL(STRING_AGG(QUOTENAME(dp2.name), '', ''), ''None'')
                 FROM ' + QUOTENAME(@DbName) + N'.sys.database_permissions p2
                 JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals dp2 ON p2.grantee_principal_id = dp2.principal_id
                 WHERE dp2.type <> ''R'' AND dp2.name NOT IN (''dbo'', ''sys'', ''INFORMATION_SCHEMA''))
            FROM ' + QUOTENAME(@DbName) + N'.sys.database_permissions p
            JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
            WHERE dp.name NOT IN (''dbo'', ''sys'', ''INFORMATION_SCHEMA'');';

            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;