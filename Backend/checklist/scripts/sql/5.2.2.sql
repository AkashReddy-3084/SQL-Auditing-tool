/* Checklist 5.2.2 - Data Quality Framework - Completeness: all expected sources/batches received */
/* Read-only metadata proxy: detects batch/source load-control artifacts and expected-vs-received reconciliation columns. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#Artifacts') IS NOT NULL DROP TABLE #Artifacts;

CREATE TABLE #Databases
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

CREATE TABLE #Artifacts
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    ObjectName   SYSNAME NOT NULL,
    HasBatchKey  BIT     NOT NULL,
    HasSourceKey BIT     NOT NULL,
    HasExpected  BIT     NOT NULL,
    HasActual    BIT     NOT NULL,
    HasStatus    BIT     NOT NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database queries are not supported, scope to the current database. */
    INSERT INTO #Databases (DatabaseName)
    VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db     SYSNAME;
DECLARE @prefix NVARCHAR(300);
DECLARE @sql    NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @prefix = CASE WHEN @EngineEdition = 5 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        SET @sql = N'
SELECT @dbname AS DatabaseName,
       s.name AS SchemaName,
       t.name AS ObjectName,
       MAX(CASE WHEN c.name LIKE ''%batch%''
                  OR c.name LIKE ''%load[_]id%''
                  OR c.name LIKE ''%loadid%''
                  OR c.name LIKE ''%run[_]id%''
                  OR c.name LIKE ''%runid%''
                  OR c.name LIKE ''%cycle%''
                  OR c.name LIKE ''%execution%''
                THEN 1 ELSE 0 END) AS HasBatchKey,
       MAX(CASE WHEN c.name LIKE ''%source%''
                  OR c.name LIKE ''%feed%''
                  OR c.name LIKE ''%file%''
                  OR c.name LIKE ''%provider%''
                  OR c.name LIKE ''%vendor%''
                  OR c.name LIKE ''%system[_]name%''
                THEN 1 ELSE 0 END) AS HasSourceKey,
       MAX(CASE WHEN c.name LIKE ''%expected%''
                  OR c.name LIKE ''%planned%''
                  OR c.name LIKE ''%required%''
                  OR c.name LIKE ''%target[_]count%''
                  OR c.name LIKE ''%control[_]total%''
                THEN 1 ELSE 0 END) AS HasExpected,
       MAX(CASE WHEN c.name LIKE ''%received%''
                  OR c.name LIKE ''%actual%''
                  OR c.name LIKE ''%row[_]count%''
                  OR c.name LIKE ''%rowcount%''
                  OR c.name LIKE ''%record[_]count%''
                  OR c.name LIKE ''%loaded%''
                  OR c.name LIKE ''%inserted%''
                THEN 1 ELSE 0 END) AS HasActual,
       MAX(CASE WHEN c.name LIKE ''%status%''
                  OR c.name LIKE ''%complete%''
                  OR c.name LIKE ''%success%''
                  OR c.name LIKE ''%missing%''
                  OR c.name LIKE ''%result%''
                THEN 1 ELSE 0 END) AS HasStatus
FROM ' + @prefix + N'sys.tables AS t
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN ' + @prefix + N'sys.columns AS c ON c.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND (   t.name LIKE ''%batch%''
       OR t.name LIKE ''%load%''
       OR t.name LIKE ''%ingest%''
       OR t.name LIKE ''%feed%''
       OR t.name LIKE ''%import%''
       OR t.name LIKE ''%extract%''
       OR t.name LIKE ''%etl%''
       OR t.name LIKE ''%control%''
       OR t.name LIKE ''%audit%''
       OR t.name LIKE ''%staging%''
       OR t.name LIKE ''%reconcil%''
       OR t.name LIKE ''%file[_]log%''
       OR t.name LIKE ''%process[_]log%''
       OR t.name LIKE ''%job[_]log%''
       OR s.name LIKE ''%audit%''
       OR s.name LIKE ''%control%''
       OR s.name LIKE ''%etl%'')
GROUP BY s.name, t.name;';

        INSERT INTO #Artifacts (DatabaseName, SchemaName, ObjectName, HasBatchKey, HasSourceKey, HasExpected, HasActual, HasStatus)
        EXEC sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
    END TRY
    BEGIN CATCH
        /* Database unreadable (offline, restoring, non-readable replica, or no permission) - skipped. */
    END CATCH

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DatabasesScanned  INT = (SELECT COUNT(*) FROM #Databases);

DECLARE @ReconcileObjects  INT =
(
    SELECT COUNT(*) FROM #Artifacts
    WHERE (HasBatchKey = 1 OR HasSourceKey = 1) AND HasExpected = 1 AND HasActual = 1
);

DECLARE @TrackingObjects   INT =
(
    SELECT COUNT(*) FROM #Artifacts
    WHERE (HasBatchKey = 1 OR HasSourceKey = 1) AND (HasActual = 1 OR HasStatus = 1)
);

DECLARE @ReconcileDbs      INT =
(
    SELECT COUNT(DISTINCT DatabaseName) FROM #Artifacts
    WHERE (HasBatchKey = 1 OR HasSourceKey = 1) AND HasExpected = 1 AND HasActual = 1
);

DECLARE @TrackingDbs       INT =
(
    SELECT COUNT(DISTINCT DatabaseName) FROM #Artifacts
    WHERE (HasBatchKey = 1 OR HasSourceKey = 1) AND (HasActual = 1 OR HasStatus = 1)
);

DECLARE @Examples NVARCHAR(2000) =
    STUFF((SELECT TOP (5) N'; ' + a.DatabaseName + N'.' + a.SchemaName + N'.' + a.ObjectName
           FROM #Artifacts AS a
           WHERE (a.HasBatchKey = 1 OR a.HasSourceKey = 1)
             AND (a.HasExpected = 1 OR a.HasActual = 1 OR a.HasStatus = 1)
           ORDER BY a.HasExpected DESC, a.HasActual DESC, a.DatabaseName, a.SchemaName, a.ObjectName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(2000)'), 1, 2, N'');

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Databases AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DatabaseQueried IS NULL SET @DatabaseQueried = N'None (no accessible user databases)';
IF @Examples IS NULL SET @Examples = N'none';

DECLARE @Score  INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

IF @ReconcileObjects > 0
    SET @Score = 3;
ELSE IF @TrackingObjects > 0
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE @Score WHEN 3 THEN N'Pass' WHEN 2 THEN N'NeedsReview' ELSE N'Fail' END;

SET @Finding =
    N'Scanned ' + CAST(@DatabasesScanned AS NVARCHAR(10)) + N' accessible user database(s). '
  + N'Batch/source-keyed load or audit control tables with expected-vs-received count columns: '
  + CAST(@ReconcileObjects AS NVARCHAR(10)) + N' object(s) across ' + CAST(@ReconcileDbs AS NVARCHAR(10)) + N' database(s). '
  + N'Batch/source-keyed tables logging received counts or load status only: '
  + CAST(@TrackingObjects AS NVARCHAR(10)) + N' object(s) across ' + CAST(@TrackingDbs AS NVARCHAR(10)) + N' database(s). '
  + CASE @Score
        WHEN 3 THEN N'Expected-versus-received reconciliation of sources/batches is implemented in the database. '
        WHEN 2 THEN N'Arrivals of sources/batches are logged, but no expected/planned baseline column was found, so completeness cannot be proven from the data. '
        ELSE N'No batch, feed or source completeness-tracking control objects were found. '
    END
  + N'Example objects: ' + @Examples + N'.';

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Artifacts') IS NOT NULL DROP TABLE #Artifacts;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;