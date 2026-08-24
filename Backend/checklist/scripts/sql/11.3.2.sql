-- Checklist: Production access restricted (no developer write/deploy)
-- Scope: DATABASE
-- Scoring: 3 = 0% of non-service-like users hold write-capable roles (db_owner/db_datawriter/db_ddladmin); 2 = under 25% do; 1 = 25%+ do; 0 = no database users found
-- NOTE: Automated evidence only; identifying "developer" accounts relies on a naming heuristic (excluding service/app/managed-identity patterns), not organizational role records. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @NonServiceUserCount INT, @WriteAccessNonServiceCount INT;

    SELECT @NonServiceUserCount = COUNT(*)
    FROM sys.database_principals p
    WHERE p.type IN ('S','U','G','E','X') AND p.name NOT IN ('dbo','guest','public')
      AND p.name NOT LIKE '%svc%' AND p.name NOT LIKE '%service%' AND p.name NOT LIKE '%app\_%' ESCAPE '\'
      AND p.type NOT IN ('E','X');

    SELECT @WriteAccessNonServiceCount = COUNT(DISTINCT m.member_principal_id)
    FROM sys.database_role_members m
    JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
    JOIN sys.database_principals p ON p.principal_id = m.member_principal_id
    WHERE r.name IN ('db_owner','db_datawriter','db_ddladmin')
      AND p.name NOT IN ('dbo','guest','public')
      AND p.name NOT LIKE '%svc%' AND p.name NOT LIKE '%service%' AND p.name NOT LIKE '%app\_%' ESCAPE '\'
      AND p.type NOT IN ('E','X');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@NonServiceUserCount,0) = 0 THEN 0
             WHEN ISNULL(@WriteAccessNonServiceCount,0) = 0 THEN 3
             WHEN (CAST(@WriteAccessNonServiceCount AS DECIMAL(9,4)) / NULLIF(@NonServiceUserCount,0)) < 0.25 THEN 2
             ELSE 1 END,
        CONCAT('Non-service-like database users = ', ISNULL(@NonServiceUserCount,0), ', holding write-capable roles = ', ISNULL(@WriteAccessNonServiceCount,0))
    );
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
            SET @Sql = N'DECLARE @nu INT, @wu INT;
SELECT @nu = COUNT(*)
FROM ' + QUOTENAME(@DbName) + N'.sys.database_principals p
WHERE p.type IN (''S'',''U'',''G'',''E'',''X'') AND p.name NOT IN (''dbo'',''guest'',''public'')
  AND p.name NOT LIKE ''%svc%'' AND p.name NOT LIKE ''%service%'' AND p.name NOT LIKE ''%app\_%'' ESCAPE ''\''
  AND p.type NOT IN (''E'',''X'');
SELECT @wu = COUNT(DISTINCT m.member_principal_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.database_role_members m
JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals p ON p.principal_id = m.member_principal_id
WHERE r.name IN (''db_owner'',''db_datawriter'',''db_ddladmin'')
  AND p.name NOT IN (''dbo'',''guest'',''public'')
  AND p.name NOT LIKE ''%svc%'' AND p.name NOT LIKE ''%service%'' AND p.name NOT LIKE ''%app\_%'' ESCAPE ''\''
  AND p.type NOT IN (''E'',''X'');
SELECT @p_Db,
       CASE WHEN ISNULL(@nu,0) = 0 THEN 0
            WHEN ISNULL(@wu,0) = 0 THEN 3
            WHEN (CAST(@wu AS DECIMAL(9,4)) / NULLIF(@nu,0)) < 0.25 THEN 2
            ELSE 1 END,
       CONCAT(''Non-service-like database users = '', ISNULL(@nu,0), '', holding write-capable roles = '', ISNULL(@wu,0));';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;