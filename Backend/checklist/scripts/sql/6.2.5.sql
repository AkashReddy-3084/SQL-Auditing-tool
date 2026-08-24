-- Checklist: Row-Level Security implemented where multi-tenant/segmented access is required
-- Scope: DATABASE
-- Scoring: 3 = no tenant-key columns found (N/A) or all tenant-key tables covered by an active RLS policy; 2 = an active RLS policy exists but coverage is partial; 1 = tenant-key columns exist but no active RLS policy found; 0 = evaluation could not be run

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @TenantTableCount INT, @RlsCoveredTableCount INT;

    SELECT @TenantTableCount = COUNT(DISTINCT c.object_id)
    FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE c.name LIKE '%tenant_id%' OR c.name LIKE '%org_id%' OR c.name LIKE '%customer_id%';

    SELECT @RlsCoveredTableCount = COUNT(DISTINCT sp.target_object_id)
    FROM sys.security_predicates sp
    JOIN sys.security_policies pol ON pol.object_id = sp.object_id AND pol.is_enabled = 1;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@TenantTableCount,0) = 0 THEN 3
             WHEN ISNULL(@RlsCoveredTableCount,0) = 0 THEN 1
             WHEN @RlsCoveredTableCount >= @TenantTableCount THEN 3
             ELSE 2 END,
        CASE WHEN ISNULL(@TenantTableCount,0) = 0 THEN 'No tenant/segmentation-key columns found - RLS not applicable'
             ELSE CONCAT('Tables with tenant-key columns = ', @TenantTableCount, ', covered by an active RLS policy = ', ISNULL(@RlsCoveredTableCount,0)) END
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
            SET @Sql = N'DECLARE @tt INT, @rc INT;
SELECT @tt = COUNT(DISTINCT c.object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON t.object_id = c.object_id
WHERE c.name LIKE ''%tenant_id%'' OR c.name LIKE ''%org_id%'' OR c.name LIKE ''%customer_id%'';
SELECT @rc = COUNT(DISTINCT sp.target_object_id)
FROM ' + QUOTENAME(@DbName) + N'.sys.security_predicates sp
JOIN ' + QUOTENAME(@DbName) + N'.sys.security_policies pol ON pol.object_id = sp.object_id AND pol.is_enabled = 1;
SELECT @p_Db,
       CASE WHEN ISNULL(@tt,0) = 0 THEN 3
            WHEN ISNULL(@rc,0) = 0 THEN 1
            WHEN @rc >= @tt THEN 3
            ELSE 2 END,
       CASE WHEN ISNULL(@tt,0) = 0 THEN ''No tenant/segmentation-key columns found - RLS not applicable''
            ELSE CONCAT(''Tables with tenant-key columns = '', @tt, '', covered by an active RLS policy = '', ISNULL(@rc,0)) END;';

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