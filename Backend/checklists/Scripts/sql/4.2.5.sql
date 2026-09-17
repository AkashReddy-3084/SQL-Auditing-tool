SET NOCOUNT ON;

/* Checklist 4.2.5 - Conformed dimensions shared across facts (no duplicate versions).
   Read-only: catalog metadata only (sys.databases, sys.tables, sys.schemas, sys.foreign_keys). */

DECLARE @Result          nvarchar(20)   = NULL;
DECLARE @Score           int            = 1;
DECLARE @DatabaseQueried nvarchar(4000) = NULL;
DECLARE @Finding         nvarchar(4000) = NULL;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

IF OBJECT_ID('tempdb..#DbList')         IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#DbError')        IS NOT NULL DROP TABLE #DbError;
IF OBJECT_ID('tempdb..#DimModelTables') IS NOT NULL DROP TABLE #DimModelTables;
IF OBJECT_ID('tempdb..#DimModelFk')     IS NOT NULL DROP TABLE #DimModelFk;
IF OBJECT_ID('tempdb..#DimNorm')        IS NOT NULL DROP TABLE #DimNorm;
IF OBJECT_ID('tempdb..#DupGroup')       IS NOT NULL DROP TABLE #DupGroup;
IF OBJECT_ID('tempdb..#DbVerdict')      IS NOT NULL DROP TABLE #DbVerdict;

CREATE TABLE #DbList  (DatabaseName sysname NOT NULL PRIMARY KEY);
CREATE TABLE #DbError (DatabaseName sysname NOT NULL PRIMARY KEY, ErrorMessage nvarchar(2000) NULL);

CREATE TABLE #DimModelTables
(
    DatabaseName sysname NOT NULL,
    SchemaName   sysname NOT NULL,
    TableName    sysname NOT NULL,
    ObjectId     int     NOT NULL,
    IsFact       bit     NOT NULL,
    IsDimension  bit     NOT NULL
);

CREATE TABLE #DimModelFk
(
    DatabaseName       sysname NOT NULL,
    ParentObjectId     int     NOT NULL,
    ReferencedObjectId int     NOT NULL
);

CREATE TABLE #DimNorm
(
    DatabaseName sysname       NOT NULL,
    ObjectId     int           NOT NULL,
    BaseName     nvarchar(300) NOT NULL
);

CREATE TABLE #DupGroup
(
    DatabaseName sysname       NOT NULL,
    BaseName     nvarchar(300) NOT NULL,
    TableCount   int           NOT NULL
);

CREATE TABLE #DbVerdict
(
    DatabaseName sysname        NOT NULL PRIMARY KEY,
    HasModel     bit            NOT NULL,
    FactCount    int            NOT NULL,
    DimCount     int            NOT NULL,
    DupGroups    int            NOT NULL,
    DupTables    int            NOT NULL,
    LinkedDims   int            NOT NULL,
    SharedDims   int            NOT NULL,
    DbScore      int            NOT NULL,
    Detail       nvarchar(1000) NOT NULL
);

/* Azure SQL Database cannot query sibling databases: restrict to the current database. */
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DatabaseName) SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db sysname, @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
INSERT INTO #DimModelTables (DatabaseName, SchemaName, TableName, ObjectId, IsFact, IsDimension)
SELECT @dbn, s.name, t.name, t.object_id,
       CASE WHEN t.name LIKE N''Fact%'' OR t.name LIKE N''%[_]Fact'' OR t.name LIKE N''%[_]Facts'' OR t.name LIKE N''F[_]%''
            THEN 1 ELSE 0 END,
       CASE WHEN (t.name LIKE N''Dim%'' OR t.name LIKE N''%[_]Dim'' OR t.name LIKE N''%Dimension%'' OR t.name LIKE N''D[_]%'')
             AND NOT (t.name LIKE N''Fact%'' OR t.name LIKE N''%[_]Fact'' OR t.name LIKE N''%[_]Facts'' OR t.name LIKE N''F[_]%'')
            THEN 1 ELSE 0 END
FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = N''U''
  AND LOWER(s.name) NOT IN (N''stg'', N''staging'', N''etl'', N''tmp'', N''temp'', N''archive'',
                            N''load'', N''raw'', N''bronze'', N''backup'', N''bak'', N''work'', N''landing'')
  AND ( t.name LIKE N''Fact%'' OR t.name LIKE N''%[_]Fact'' OR t.name LIKE N''%[_]Facts'' OR t.name LIKE N''F[_]%''
        OR t.name LIKE N''Dim%'' OR t.name LIKE N''%[_]Dim'' OR t.name LIKE N''%Dimension%'' OR t.name LIKE N''D[_]%'' );

INSERT INTO #DimModelFk (DatabaseName, ParentObjectId, ReferencedObjectId)
SELECT DISTINCT @dbn, fk.parent_object_id, fk.referenced_object_id
FROM ' + QUOTENAME(@db) + N'.sys.foreign_keys AS fk
WHERE fk.parent_object_id <> fk.referenced_object_id;';

        EXEC sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbError (DatabaseName, ErrorMessage)
        SELECT @db, LEFT(ERROR_MESSAGE(), 2000)
        WHERE NOT EXISTS (SELECT 1 FROM #DbError AS e WHERE e.DatabaseName = @db);
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* Normalise dimension names so DimCustomer / Dim_Customer_New / CustomerDim_v2 collapse to one base name. */
INSERT INTO #DimNorm (DatabaseName, ObjectId, BaseName)
SELECT t.DatabaseName, t.ObjectId,
       CASE WHEN LEN(s6.v) = 0 THEN UPPER(t.TableName) ELSE s6.v END
FROM #DimModelTables AS t
CROSS APPLY (SELECT v = UPPER(LTRIM(RTRIM(t.TableName)))) AS s1
CROSS APPLY (SELECT v = CASE WHEN s1.v LIKE 'DIMENSION[_]%' THEN STUFF(s1.v, 1, 10, '')
                             WHEN s1.v LIKE 'DIMENSION%'    THEN STUFF(s1.v, 1, 9, '')
                             WHEN s1.v LIKE 'DIM[_]%'       THEN STUFF(s1.v, 1, 4, '')
                             WHEN s1.v LIKE 'DIM%'          THEN STUFF(s1.v, 1, 3, '')
                             WHEN s1.v LIKE 'D[_]%'         THEN STUFF(s1.v, 1, 2, '')
                             ELSE s1.v END) AS s2
CROSS APPLY (SELECT v = CASE WHEN s2.v LIKE '%[_]DIMENSION' AND LEN(s2.v) > 10 THEN LEFT(s2.v, LEN(s2.v) - 10)
                             WHEN s2.v LIKE '%DIMENSION'    AND LEN(s2.v) > 9  THEN LEFT(s2.v, LEN(s2.v) - 9)
                             WHEN s2.v LIKE '%[_]DIM'       AND LEN(s2.v) > 4  THEN LEFT(s2.v, LEN(s2.v) - 4)
                             WHEN s2.v LIKE '%DIM'          AND LEN(s2.v) > 3  THEN LEFT(s2.v, LEN(s2.v) - 3)
                             ELSE s2.v END) AS s3
CROSS APPLY (SELECT v = REPLACE(REPLACE(s3.v, '_', ''), ' ', '')) AS s4
CROSS APPLY (SELECT v = CASE WHEN s4.v LIKE '%BACKUP'  AND LEN(s4.v) > 6 THEN LEFT(s4.v, LEN(s4.v) - 6)
                             WHEN s4.v LIKE '%ARCHIVE' AND LEN(s4.v) > 7 THEN LEFT(s4.v, LEN(s4.v) - 7)
                             WHEN s4.v LIKE '%HISTORY' AND LEN(s4.v) > 7 THEN LEFT(s4.v, LEN(s4.v) - 7)
                             WHEN s4.v LIKE '%COPY'    AND LEN(s4.v) > 4 THEN LEFT(s4.v, LEN(s4.v) - 4)
                             WHEN s4.v LIKE '%TEMP'    AND LEN(s4.v) > 4 THEN LEFT(s4.v, LEN(s4.v) - 4)
                             WHEN s4.v LIKE '%HIST'    AND LEN(s4.v) > 4 THEN LEFT(s4.v, LEN(s4.v) - 4)
                             WHEN s4.v LIKE '%NEW'     AND LEN(s4.v) > 3 THEN LEFT(s4.v, LEN(s4.v) - 3)
                             WHEN s4.v LIKE '%OLD'     AND LEN(s4.v) > 3 THEN LEFT(s4.v, LEN(s4.v) - 3)
                             WHEN s4.v LIKE '%BAK'     AND LEN(s4.v) > 3 THEN LEFT(s4.v, LEN(s4.v) - 3)
                             WHEN s4.v LIKE '%TMP'     AND LEN(s4.v) > 3 THEN LEFT(s4.v, LEN(s4.v) - 3)
                             ELSE s4.v END) AS s5
CROSS APPLY (SELECT v = CASE WHEN RIGHT(s5.v, 1) LIKE '[0-9]' AND LEN(s5.v) > 1
                             THEN LEFT(s5.v, LEN(s5.v) - 1) ELSE s5.v END) AS s5b
CROSS APPLY (SELECT v = CASE WHEN RIGHT(s5b.v, 1) LIKE '[0-9]' AND LEN(s5b.v) > 1
                             THEN LEFT(s5b.v, LEN(s5b.v) - 1) ELSE s5b.v END) AS s5c
CROSS APPLY (SELECT v = CASE WHEN s5c.v <> s5.v AND RIGHT(s5c.v, 1) = 'V' AND LEN(s5c.v) > 1
                             THEN LEFT(s5c.v, LEN(s5c.v) - 1) ELSE s5c.v END) AS s6
WHERE t.IsDimension = 1;

INSERT INTO #DupGroup (DatabaseName, BaseName, TableCount)
SELECT n.DatabaseName, n.BaseName, COUNT(*)
FROM #DimNorm AS n
GROUP BY n.DatabaseName, n.BaseName
HAVING COUNT(*) > 1;

INSERT INTO #DbVerdict (DatabaseName, HasModel, FactCount, DimCount, DupGroups, DupTables, LinkedDims, SharedDims, DbScore, Detail)
SELECT l.DatabaseName,
       CASE WHEN v.FactCount > 0 AND v.DimCount > 0 THEN 1 ELSE 0 END,
       v.FactCount, v.DimCount, v.DupGroups, v.DupTables, v.LinkedDims, v.SharedDims,
       CASE
           WHEN v.DupGroups > 0                               THEN 0
           WHEN v.FactCount = 0 OR v.DimCount = 0             THEN 2
           WHEN v.FactCount = 1                               THEN 2
           WHEN v.LinkedDims = 0                              THEN 2
           WHEN v.SharedDims = 0                              THEN 1
           WHEN (v.SharedDims * 100.0 / v.LinkedDims) >= 50.0 THEN 3
           ELSE 2
       END,
       LEFT(CONCAT(l.DatabaseName, ': facts=', v.FactCount, ', dims=', v.DimCount,
                   ', duplicate dim groups=', v.DupGroups, ' (', v.DupTables, ' tables)',
                   ', FK-linked dims=', v.LinkedDims, ', dims shared by 2+ facts=', v.SharedDims,
                   CASE WHEN v.DupGroups > 0 THEN CONCAT('; duplicates: ', ISNULL(dn.SampleTables, 'n/a')) ELSE '' END), 1000)
FROM #DbList AS l
LEFT JOIN (SELECT t.DatabaseName,
                  FactCount = SUM(CASE WHEN t.IsFact = 1 THEN 1 ELSE 0 END),
                  DimCount  = SUM(CASE WHEN t.IsDimension = 1 THEN 1 ELSE 0 END)
           FROM #DimModelTables AS t
           GROUP BY t.DatabaseName) AS m ON m.DatabaseName = l.DatabaseName
LEFT JOIN (SELECT g.DatabaseName, DupGroups = COUNT(*), DupTables = SUM(g.TableCount)
           FROM #DupGroup AS g
           GROUP BY g.DatabaseName) AS gg ON gg.DatabaseName = l.DatabaseName
LEFT JOIN (SELECT u.DatabaseName,
                  LinkedDims = COUNT(*),
                  SharedDims = SUM(CASE WHEN u.FactRefs >= 2 THEN 1 ELSE 0 END)
           FROM (SELECT k.DatabaseName,
                        DimObjectId = k.ReferencedObjectId,
                        FactRefs = COUNT(DISTINCT k.ParentObjectId)
                 FROM #DimModelFk AS k
                 INNER JOIN #DimModelTables AS f
                         ON f.DatabaseName = k.DatabaseName AND f.ObjectId = k.ParentObjectId AND f.IsFact = 1
                 INNER JOIN #DimModelTables AS d
                         ON d.DatabaseName = k.DatabaseName AND d.ObjectId = k.ReferencedObjectId AND d.IsDimension = 1
                 GROUP BY k.DatabaseName, k.ReferencedObjectId) AS u
           GROUP BY u.DatabaseName) AS uu ON uu.DatabaseName = l.DatabaseName
OUTER APPLY (SELECT SampleTables = STUFF((SELECT TOP (10) ', ' + t2.SchemaName + '.' + t2.TableName
                                          FROM #DimNorm AS n2
                                          INNER JOIN #DimModelTables AS t2
                                                  ON t2.DatabaseName = n2.DatabaseName AND t2.ObjectId = n2.ObjectId
                                          INNER JOIN #DupGroup AS g2
                                                  ON g2.DatabaseName = n2.DatabaseName AND g2.BaseName = n2.BaseName
                                          WHERE n2.DatabaseName = l.DatabaseName
                                          ORDER BY n2.BaseName, t2.SchemaName, t2.TableName
                                          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')) AS dn
CROSS APPLY (SELECT FactCount  = ISNULL(m.FactCount, 0),
                    DimCount   = ISNULL(m.DimCount, 0),
                    DupGroups  = ISNULL(gg.DupGroups, 0),
                    DupTables  = ISNULL(gg.DupTables, 0),
                    LinkedDims = ISNULL(uu.LinkedDims, 0),
                    SharedDims = ISNULL(uu.SharedDims, 0)) AS v
WHERE NOT EXISTS (SELECT 1 FROM #DbError AS e WHERE e.DatabaseName = l.DatabaseName);

DECLARE @DbCandidates   int = (SELECT COUNT(*) FROM #DbList);
DECLARE @DbUnreadable   int = (SELECT COUNT(*) FROM #DbError);
DECLARE @DbModelled     int = (SELECT COUNT(*) FROM #DbVerdict WHERE HasModel = 1);
DECLARE @DbWithDup      int = (SELECT COUNT(*) FROM #DbVerdict WHERE DupGroups > 0);
DECLARE @DupGroupsTotal int = (SELECT ISNULL(SUM(DupGroups), 0) FROM #DbVerdict);
DECLARE @DupTablesTotal int = (SELECT ISNULL(SUM(DupTables), 0) FROM #DbVerdict);
DECLARE @DbNotConformed int = (SELECT COUNT(*) FROM #DbVerdict WHERE HasModel = 1 AND DupGroups = 0 AND FactCount >= 2 AND LinkedDims > 0 AND SharedDims = 0);
DECLARE @DbPartial      int = (SELECT COUNT(*) FROM #DbVerdict WHERE HasModel = 1 AND DbScore = 2);
DECLARE @DbConformed    int = (SELECT COUNT(*) FROM #DbVerdict WHERE HasModel = 1 AND DbScore = 3);

SET @DatabaseQueried = LEFT(ISNULL(STUFF((SELECT TOP (25) ', ' + CAST(v.DatabaseName AS nvarchar(128))
                                          FROM #DbVerdict AS v
                                          WHERE v.HasModel = 1
                                          ORDER BY v.DbScore, v.DatabaseName
                                          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''),
                            CASE WHEN @DbCandidates = 0 THEN CAST(ISNULL(@@SERVERNAME, 'UNKNOWN') AS nvarchar(128))
                                 ELSE CONCAT(@DbCandidates, ' user database(s) - no dimensional model detected') END), 4000);

SET @Score = CASE
                 WHEN @DbCandidates = 0   THEN 1
                 WHEN @DbWithDup > 0      THEN 0
                 WHEN @DbNotConformed > 0 THEN 1
                 WHEN @DbModelled = 0     THEN 2
                 WHEN @DbPartial > 0      THEN 2
                 ELSE 3
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = LEFT(CONCAT(
    CASE
        WHEN @DbCandidates = 0 THEN
            'No accessible user databases were found on this instance, so conformed-dimension usage could not be evaluated.'
        WHEN @DbWithDup > 0 THEN
            CONCAT('Duplicate dimension versions detected: ', @DupGroupsTotal,
                   ' base dimension name(s) implemented by ', @DupTablesTotal,
                   ' tables across ', @DbWithDup, ' database(s).')
        WHEN @DbNotConformed > 0 THEN
            CONCAT('No duplicate dimension versions found, but ', @DbNotConformed,
                   ' database(s) have 2 or more fact tables where every FK-linked dimension is used by exactly one fact - dimensions are siloed rather than conformed.')
        WHEN @DbModelled = 0 THEN
            CONCAT('No fact/dimension model was detected in any of the ', @DbCandidates,
                   ' accessible user database(s) using the Fact*/Dim*/*_Fact/*_Dim naming conventions, so no duplicate or non-conformed dimensions exist to report.')
        WHEN @DbPartial > 0 THEN
            CONCAT('No duplicate dimension versions found, but conformance is not fully demonstrated in ', @DbPartial,
                   ' of ', @DbModelled, ' modelled database(s) (single fact table, no fact-to-dimension foreign keys, or fewer than 50% of linked dimensions shared by 2+ facts).')
        ELSE
            CONCAT('Conformed dimensions confirmed in all ', @DbModelled,
                   ' modelled database(s): no duplicate dimension versions, and at least half of the FK-linked dimensions in each are referenced by 2 or more fact tables.')
    END,
    ' [databases examined=', @DbCandidates,
    ', unreadable=', @DbUnreadable,
    ', modelled=', @DbModelled,
    ', conformed=', @DbConformed,
    ', partial=', @DbPartial,
    ', not conformed=', @DbNotConformed,
    ', with duplicate dimensions=', @DbWithDup, ']',
    ISNULL(NULLIF(CONCAT(' Detail: ', STUFF((SELECT TOP (15) ' | ' + v.Detail
                                             FROM #DbVerdict AS v
                                             WHERE v.HasModel = 1
                                             ORDER BY v.DbScore, v.DatabaseName
                                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, '')), ' Detail: '), '')
), 4000);

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #DbVerdict;
DROP TABLE #DupGroup;
DROP TABLE #DimNorm;
DROP TABLE #DimModelFk;
DROP TABLE #DimModelTables;
DROP TABLE #DbError;
DROP TABLE #DbList;