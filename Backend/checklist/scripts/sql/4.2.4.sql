-- Checklist: Surrogate keys used for dimensions (IDENTITY/sequence), not business keys in facts
-- Scope: DATABASE
-- Scoring: 3 = no issues; 2 = < 5% non-compliant; 1 = 5-25% non-compliant; 0 = > 25% non-compliant

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
            WHEN TotalTables = 0 THEN 3 
            WHEN CAST(NonCompliantCount AS FLOAT) * 100.0 / TotalTables < 5 THEN 2 
            WHEN CAST(NonCompliantCount AS FLOAT) * 100.0 / TotalTables < 25 THEN 1 
            ELSE 0 
        END,
        CASE 
            WHEN NonCompliantCount = 0 THEN 'No non-compliant tables found'
            ELSE 'Non-compliant: ' + ISNULL(NonCompliantList, '') 
        END
    FROM (
        SELECT 
            COUNT(*) AS TotalTables,
            SUM(CASE WHEN (t.name LIKE 'Dim%' AND NOT EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = t.object_id))
                      OR (t.name LIKE 'Fact%' AND EXISTS (
                          SELECT 1 FROM sys.foreign_keys fk 
                          JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
                          WHERE fk.parent_object_id = t.object_id 
                          AND NOT EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = fk.referenced_object_id AND ic.column_id = fkc.referenced_column_id)
                      )) THEN 1 ELSE 0 END) AS NonCompliantCount,
            STRING_AGG(CASE WHEN (t.name LIKE 'Dim%' AND NOT EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = t.object_id))
                             OR (t.name LIKE 'Fact%' AND EXISTS (
                                 SELECT 1 FROM sys.foreign_keys fk 
                                 JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
                                 WHERE fk.parent_object_id = t.object_id 
                                 AND NOT EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = fk.referenced_object_id AND ic.column_id = fkc.referenced_column_id)
                             )) THEN QUOTENAME(s.name) + '.' + QUOTENAME(t.name) END, ', ') AS NonCompliantList
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.name LIKE 'Dim%' OR t.name LIKE 'Fact%'
    ) AS Stats;
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
            SET @Sql = N'
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT 
                @p_Db,
                CASE 
                    WHEN TotalTables = 0 THEN 3 
                    WHEN CAST(NonCompliantCount AS FLOAT) * 100.0 / TotalTables < 5 THEN 2 
                    WHEN CAST(NonCompliantCount AS FLOAT) * 100.0 / TotalTables < 25 THEN 1 
                    ELSE 0 
                END,
                CASE 
                    WHEN NonCompliantCount = 0 THEN ''No non-compliant tables found''
                    ELSE ''Non-compliant: '' + ISNULL(NonCompliantList, '''') 
                END
            FROM (
                SELECT 
                    COUNT(*) AS TotalTables,
                    SUM(CASE WHEN (t.name LIKE ''Dim%'' AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = t.object_id))
                              OR (t.name LIKE ''Fact%'' AND EXISTS (
                                  SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk 
                                  JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
                                  WHERE fk.parent_object_id = t.object_id 
                                  AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = fk.referenced_object_id AND ic.column_id = fkc.referenced_column_id)
                              )) THEN 1 ELSE 0 END) AS NonCompliantCount,
                    STRING_AGG(CASE WHEN (t.name LIKE ''Dim%'' AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = t.object_id))
                                     OR (t.name LIKE ''Fact%'' AND EXISTS (
                                         SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk 
                                         JOIN ' + QUOTENAME(@DbName) + N'.sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
                                         WHERE fk.parent_object_id = t.object_id 
                                         AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.identity_columns ic WHERE ic.object_id = fk.referenced_object_id AND ic.column_id = fkc.referenced_column_id)
                                     )) THEN QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) END, '', '') AS NonCompliantList
                FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
                WHERE t.name LIKE ''Dim%'' OR t.name LIKE ''Fact%''
            ) AS Stats;';

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