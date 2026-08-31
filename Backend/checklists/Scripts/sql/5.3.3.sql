SET NOCOUNT ON;

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSqlDb bit = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#AuditDbs') IS NOT NULL DROP TABLE #AuditDbs;
IF OBJECT_ID('tempdb..#AuditTables') IS NOT NULL DROP TABLE #AuditTables;

CREATE TABLE #AuditDbs (DatabaseName sysname NOT NULL PRIMARY KEY);

CREATE TABLE #AuditTables (
    RowId int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    ApproxRows bigint NOT NULL,
    HasBusinessKeyUniqueness bit NOT NULL,
    CandidateKeyColumn sysname NULL,
    DuplicateGroups bigint NULL,
    ProbeStatus nvarchar(20) NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #AuditDbs (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #AuditDbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND d.state_desc = N'ONLINE'
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = N'READ_WRITE';
END

DECLARE @db sysname;
DECLARE @exec nvarchar(400);
DECLARE @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #AuditDbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @exec = CASE WHEN @IsAzureSqlDb = 1 THEN N'sys.sp_executesql' ELSE QUOTENAME(@db) + N'.sys.sp_executesql' END;

    SET @sql = N'
INSERT INTO #AuditTables (DatabaseName, SchemaName, TableName, ApproxRows, HasBusinessKeyUniqueness, CandidateKeyColumn, ProbeStatus)
SELECT DB_NAME(),
       s.name,
       t.name,
       ISNULL((SELECT SUM(p.rows) FROM sys.partitions AS p
                WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0),
       CASE WHEN EXISTS (
                SELECT 1
                FROM sys.indexes AS i
                WHERE i.object_id = t.object_id
                  AND i.is_unique = 1
                  AND i.is_disabled = 0
                  AND EXISTS (
                        SELECT 1
                        FROM sys.index_columns AS ic
                        JOIN sys.columns AS c
                          ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id
                          AND ic.index_id = i.index_id
                          AND ic.is_included_column = 0
                          AND c.is_identity = 0)
            ) THEN 1 ELSE 0 END,
       (SELECT TOP (1) c2.name
          FROM sys.columns AS c2
          JOIN sys.types AS ty ON ty.user_type_id = c2.user_type_id
         WHERE c2.object_id = t.object_id
           AND c2.is_identity = 0
           AND c2.is_computed = 0
           AND c2.is_nullable = 0
           AND c2.max_length BETWEEN 1 AND 900
           AND ty.name IN (N''int'', N''bigint'', N''smallint'', N''char'', N''nchar'', N''varchar'', N''nvarchar'', N''uniqueidentifier'')
           AND (c2.name LIKE N''%businesskey''
                OR c2.name LIKE N''%naturalkey''
                OR c2.name LIKE N''%code''
                OR c2.name LIKE N''%key''
                OR c2.name LIKE N''%number''
                OR c2.name LIKE N''%reference''
                OR c2.name LIKE N''%email''
                OR c2.name LIKE N''%[_]id'')
         ORDER BY CASE WHEN c2.name LIKE N''%businesskey'' THEN 1
                       WHEN c2.name LIKE N''%naturalkey'' THEN 2
                       WHEN c2.name LIKE N''%code'' THEN 3
                       WHEN c2.name LIKE N''%key'' THEN 4
                       WHEN c2.name LIKE N''%number'' THEN 5
                       ELSE 6 END, c2.column_id),
       N''NotProbed''
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = N''U''
  AND s.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'');';

    BEGIN TRY
        EXEC @exec @sql;
    END TRY
    BEGIN CATCH
        PRINT N'Metadata collection skipped for database: ' + @db;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @probeId int, @pdb sysname, @psch sysname, @ptab sysname, @pcol sysname;
DECLARE @dupes bigint;
DECLARE @probeCount int = 0;
DECLARE @maxProbes int = 200;

DECLARE probe_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT RowId, DatabaseName, SchemaName, TableName, CandidateKeyColumn
    FROM #AuditTables
    WHERE HasBusinessKeyUniqueness = 0
      AND CandidateKeyColumn IS NOT NULL
      AND ApproxRows BETWEEN 2 AND 2000000
    ORDER BY ApproxRows DESC;

OPEN probe_cur;
FETCH NEXT FROM probe_cur INTO @probeId, @pdb, @psch, @ptab, @pcol;

WHILE @@FETCH_STATUS = 0 AND @probeCount < @maxProbes
BEGIN
    SET @dupes = NULL;
    SET @exec = CASE WHEN @IsAzureSqlDb = 1 THEN N'sys.sp_executesql' ELSE QUOTENAME(@pdb) + N'.sys.sp_executesql' END;
    SET @sql = N'SELECT @dupOut = COUNT_BIG(*) FROM (SELECT ' + QUOTENAME(@pcol) +
               N' FROM ' + QUOTENAME(@psch) + N'.' + QUOTENAME(@ptab) +
               N' GROUP BY ' + QUOTENAME(@pcol) + N' HAVING COUNT_BIG(*) > 1) AS d;';

    BEGIN TRY
        EXEC @exec @sql, N'@dupOut bigint OUTPUT', @dupes OUTPUT;
        UPDATE #AuditTables
           SET DuplicateGroups = ISNULL(@dupes, 0),
               ProbeStatus = N'Probed'
         WHERE RowId = @probeId;
    END TRY
    BEGIN CATCH
        UPDATE #AuditTables
           SET ProbeStatus = N'Error'
         WHERE RowId = @probeId;
    END CATCH

    SET @probeCount = @probeCount + 1;
    FETCH NEXT FROM probe_cur INTO @probeId, @pdb, @psch, @ptab, @pcol;
END

CLOSE probe_cur;
DEALLOCATE probe_cur;

DECLARE @TotalTables int = (SELECT COUNT(*) FROM #AuditTables);
DECLARE @EnforcedTables int = (SELECT COUNT(*) FROM #AuditTables WHERE HasBusinessKeyUniqueness = 1);
DECLARE @ProbedTables int = (SELECT COUNT(*) FROM #AuditTables WHERE ProbeStatus = N'Probed');
DECLARE @TablesWithDupes int = (SELECT COUNT(*) FROM #AuditTables WHERE ISNULL(DuplicateGroups, 0) > 0);
DECLARE @DupGroupTotal bigint = (SELECT ISNULL(SUM(DuplicateGroups), 0) FROM #AuditTables WHERE ISNULL(DuplicateGroups, 0) > 0);
DECLARE @DbCount int = (SELECT COUNT(*) FROM #AuditDbs);
DECLARE @PctEnforced decimal(5, 2) =
    CASE WHEN (SELECT COUNT(*) FROM #AuditTables) = 0 THEN CONVERT(decimal(5, 2), 0)
         ELSE CONVERT(decimal(5, 2), (SELECT COUNT(*) FROM #AuditTables WHERE HasBusinessKeyUniqueness = 1) * 100.0
                                     / (SELECT COUNT(*) FROM #AuditTables)) END;

DECLARE @DbList nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
             FROM #AuditDbs AS d
            ORDER BY d.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @DbList = ISNULL(@DbList, N'No accessible user databases');

DECLARE @DupSample nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + a.DatabaseName + N'.' + a.SchemaName + N'.' + a.TableName +
                  N'.' + ISNULL(a.CandidateKeyColumn, N'(unknown)') +
                  N' = ' + CONVERT(nvarchar(20), a.DuplicateGroups) + N' duplicate key groups'
             FROM #AuditTables AS a
            WHERE ISNULL(a.DuplicateGroups, 0) > 0
            ORDER BY a.DuplicateGroups DESC
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @DupSample = ISNULL(@DupSample, N'none');

DECLARE @UnenforcedSample nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + a.DatabaseName + N'.' + a.SchemaName + N'.' + a.TableName
             FROM #AuditTables AS a
            WHERE a.HasBusinessKeyUniqueness = 0
            ORDER BY a.ApproxRows DESC
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @UnenforcedSample = ISNULL(@UnenforcedSample, N'none');

DECLARE @Score int;

IF @TotalTables = 0
    SET @Score = 0;
ELSE IF @TablesWithDupes = 0 AND @PctEnforced >= 90
    SET @Score = 3;
ELSE IF @TablesWithDupes = 0 AND @PctEnforced >= 60
    SET @Score = 2;
ELSE
    SET @Score = 1;

DECLARE @Result nvarchar(20);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding nvarchar(max) =
    N'Deduplication verification across ' + CONVERT(nvarchar(20), @DbCount) +
    N' database(s): ' + CONVERT(nvarchar(20), @TotalTables) + N' user table(s) inspected, ' +
    CONVERT(nvarchar(20), @EnforcedTables) + N' (' + CONVERT(nvarchar(20), @PctEnforced) +
    N'%) enforce uniqueness on a non-identity business key. ' +
    CONVERT(nvarchar(20), @ProbedTables) + N' unenforced table(s) were data-probed on a candidate natural-key column; ' +
    CONVERT(nvarchar(20), @TablesWithDupes) + N' table(s) contain duplicate business key values (' +
    CONVERT(nvarchar(20), @DupGroupTotal) + N' duplicate key group(s) in total). ' +
    N'Duplicate examples: ' + @DupSample + N'. Tables without business-key uniqueness (largest first): ' + @UnenforcedSample + N'.' +
    CASE WHEN @Score = 0
         THEN N' No user tables were visible to the audit login, so post-load deduplication could not be evidenced.'
         WHEN @Score = 3 THEN N' No duplicate business keys were detected after load.'
         WHEN @Score = 2 THEN N' No duplicates detected, but business-key uniqueness is only partially enforced by constraints.'
         ELSE N' Duplicate business keys and/or widespread missing uniqueness enforcement indicate deduplication is not verified after load.'
    END;

SELECT @Result AS Result,
       @Score AS Score,
       @DbList AS DatabaseQueried,
       @Finding AS Finding;