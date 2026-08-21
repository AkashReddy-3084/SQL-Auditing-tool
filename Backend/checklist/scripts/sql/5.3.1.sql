-- Checklist 5.3.1 - Referential integrity validated (FKs in facts match dimensions)
-- Read-only. Evaluates every accessible user database (or the connected database on Azure SQL Database).
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = N'None';
DECLARE @Finding NVARCHAR(MAX) = N'No database found to be queried';
DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults
(
    DbName     SYSNAME NOT NULL,
    FactTables INT     NOT NULL,
    GoodFacts  INT     NOT NULL,
    BadFks     INT     NOT NULL,
    DbScore    INT     NOT NULL
);

DECLARE @DbName SYSNAME;
DECLARE @Prefix NVARCHAR(300);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @FactTables INT;
DECLARE @Good INT;
DECLARE @Bad INT;
DECLARE @DbScore INT;
DECLARE @Pct DECIMAL(9, 2);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONVERT(SYSNAME, DB_NAME())
    WHERE @IsAzureDb = 1
    UNION ALL
    SELECT d.name
    FROM sys.databases AS d
    WHERE @IsAzureDb = 0
      AND d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;
    SET @FactTables = 0;
    SET @Good = 0;
    SET @Bad = 0;

    SET @Sql =
        N'SELECT @pFactTables = COUNT(*), @pGood = ISNULL(SUM(f.GoodFact), 0), @pBad = ISNULL(SUM(f.BadFk), 0)
          FROM (
              SELECT
                  CASE WHEN EXISTS (
                           SELECT 1
                           FROM ' + @Prefix + N'sys.foreign_keys AS k
                           JOIN ' + @Prefix + N'sys.tables AS rt ON rt.object_id = k.referenced_object_id
                           JOIN ' + @Prefix + N'sys.schemas AS rs ON rs.schema_id = rt.schema_id
                           WHERE k.parent_object_id = t.object_id
                             AND k.is_disabled = 0
                             AND k.is_not_trusted = 0
                             AND (rs.name = ''dim'' OR rt.name LIKE ''Dim%'' OR rt.name LIKE ''D[_]%'' OR rt.name LIKE ''%[_]Dim'')
                       ) THEN 1 ELSE 0 END AS GoodFact,
                  (SELECT COUNT(*)
                   FROM ' + @Prefix + N'sys.foreign_keys AS k2
                   WHERE k2.parent_object_id = t.object_id
                     AND (k2.is_disabled = 1 OR k2.is_not_trusted = 1)) AS BadFk
              FROM ' + @Prefix + N'sys.tables AS t
              JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
              WHERE t.is_ms_shipped = 0
                AND (s.name = ''fact'' OR t.name LIKE ''Fact%'' OR t.name LIKE ''fct[_]%'' OR t.name LIKE ''F[_]%'' OR t.name LIKE ''%[_]Fact'')
          ) AS f;';

    BEGIN TRY
        EXEC sp_executesql @Sql,
             N'@pFactTables INT OUTPUT, @pGood INT OUTPUT, @pBad INT OUTPUT',
             @pFactTables = @FactTables OUTPUT, @pGood = @Good OUTPUT, @pBad = @Bad OUTPUT;

        IF ISNULL(@FactTables, 0) > 0
        BEGIN
            SET @Pct = (ISNULL(@Good, 0) * 100.0) / @FactTables;
            SET @DbScore = CASE
                               WHEN @Pct >= 100 AND ISNULL(@Bad, 0) = 0 THEN 3
                               WHEN @Pct >= 80 THEN 2
                               WHEN @Pct >= 50 THEN 1
                               ELSE 0
                           END;

            INSERT INTO #DbResults (DbName, FactTables, GoodFacts, BadFks, DbScore)
            VALUES (@DbName, @FactTables, ISNULL(@Good, 0), ISNULL(@Bad, 0), @DbScore);
        END
    END TRY
    BEGIN CATCH
        -- Database not readable by the audit login; leave it out of the evaluated set.
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

IF EXISTS (SELECT 1 FROM #DbResults)
BEGIN
    SELECT @Score = MIN(r.DbScore) FROM #DbResults AS r;

    SET @DatabaseQueried = ISNULL(STUFF((SELECT N', ' + r.DbName
                                         FROM #DbResults AS r
                                         ORDER BY r.DbName
                                         FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'None');

    SET @Finding = ISNULL(STUFF((SELECT N'; ' + r.DbName + N': ' + CONVERT(NVARCHAR(20), r.GoodFacts) + N' of '
                                        + CONVERT(NVARCHAR(20), r.FactTables)
                                        + N' fact table(s) have an enabled and trusted FK to a dimension table, '
                                        + CONVERT(NVARCHAR(20), r.BadFks) + N' disabled/untrusted FK(s), score '
                                        + CONVERT(NVARCHAR(10), r.DbScore)
                                 FROM #DbResults AS r
                                 ORDER BY r.DbName
                                 FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''),
                          N'No database found to be queried');

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;
END

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;