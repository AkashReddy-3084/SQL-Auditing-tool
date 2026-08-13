-- Checklist: Staging area is transient/isolated and not queried by consumers
-- Scope: DATABASE
-- Scoring: 0=No staging or fully exposed; 1=Staging exists but has direct consumer access/dependencies; 2=Staging isolated but relies on naming conventions/proxy checks; 3=Staging fully isolated, no consumer access, and transient design confirmed.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DbScore INT = 0;
        DECLARE @StagingCount INT = 0;
        DECLARE @PublicAccess INT = 0;
        DECLARE @DirectDeps INT = 0;
        DECLARE @IndexedStaging INT = 0;

        -- 1. Identify staging objects (schemas or tables)
        SELECT @StagingCount = COUNT(*) FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%''
           OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%'';

        IF @StagingCount = 0
            SET @DbScore = 0;
        ELSE
        BEGIN
            -- 2. Check for direct SELECT grants to public or consumer roles
            SELECT @PublicAccess = COUNT(*) FROM sys.database_permissions dp
            JOIN sys.objects o ON dp.major_id = o.object_id
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
            WHERE dp.type = ''SELECT'' AND dp.state_desc = ''GRANT''
              AND (p.name = ''public'' OR p.name LIKE ''%user%'' OR p.name LIKE ''%consumer%'' OR p.name LIKE ''%app%'')
              AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%''
                   OR o.name LIKE ''%stg%'' OR o.name LIKE ''%landing%'' OR o.name LIKE ''%raw%'');

            -- 3. Check for direct dependencies from non-staging objects
            SELECT @DirectDeps = COUNT(*) FROM sys.sql_expression_dependencies d
            JOIN sys.objects ref_obj ON d.referenced_id = ref_obj.object_id
            JOIN sys.schemas ref_s ON ref_obj.schema_id = ref_s.schema_id
            JOIN sys.objects referrer_obj ON d.referencing_id = referrer_obj.object_id
            JOIN sys.schemas referrer_s ON referrer_obj.schema_id = referrer_s.schema_id
            WHERE d.class = 1 AND d.is_ambiguous = 0
              AND (ref_s.name LIKE ''%stg%'' OR ref_s.name LIKE ''%landing%'' OR ref_s.name LIKE ''%raw%''
                   OR ref_obj.name LIKE ''%stg%'' OR ref_obj.name LIKE ''%landing%'' OR ref_obj.name LIKE ''%raw%'')
              AND NOT (referrer_s.name LIKE ''%stg%'' OR referrer_s.name LIKE ''%landing%'' OR referrer_s.name LIKE ''%raw%'');

            IF @PublicAccess > 0 OR @DirectDeps > 0
                SET @DbScore = 1;
            ELSE
            BEGIN
                -- 4. Check transient characteristic: staging tables should ideally be heaps (no indexes)
                SELECT @IndexedStaging = COUNT(*) FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.type = ''U'' AND t.is_ms_shipped = 0
                  AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%''
                       OR t.name LIKE ''%stg%'' OR t.name LIKE ''%landing%'' OR t.name LIKE ''%raw%'')
                  AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type > 0);

                IF @IndexedStaging = 0
                    SET @DbScore = 3;
                ELSE
                    SET @DbScore = 2;
            END
        END;

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);
        ';
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