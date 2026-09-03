/*
    Checklist Item : 8.1.3 - Objects tagged/classified with business domain and owner
    Area           : Data Governance
    Purpose        : Measure the proportion of user tables and views that carry extended-property
                     metadata identifying BOTH a business domain / subject area AND a data
                     owner / steward.
    Safety         : Strictly read-only. Only catalog views are read; the only write is to a
                     session-local temp table used to accumulate per-database counts.
    Compatibility  : SQL Server 2012+ and Azure SQL Database. On Azure SQL Database
                     (EngineEdition = 5) cross-database access is unavailable, so only the
                     current database is inspected.
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#TagCoverage') IS NOT NULL
    DROP TABLE #TagCoverage;

CREATE TABLE #TagCoverage
(
    DatabaseName sysname NOT NULL,
    TotalObjects int     NOT NULL,
    DomainTagged int     NOT NULL,
    OwnerTagged  int     NOT NULL,
    FullyTagged  int     NOT NULL
);

/* Per-database probe: counts user tables/views and their governance tagging. */
DECLARE @Stmt nvarchar(max) = N'
INSERT INTO #TagCoverage (DatabaseName, TotalObjects, DomainTagged, OwnerTagged, FullyTagged)
SELECT DB_NAME(),
       COUNT(*),
       ISNULL(SUM(CASE WHEN p.HasDomain = 1 THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN p.HasOwner  = 1 THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN p.HasDomain = 1 AND p.HasOwner = 1 THEN 1 ELSE 0 END), 0)
FROM (
        SELECT o.object_id
        FROM sys.objects AS o
        WHERE o.type IN (''U'', ''V'')
          AND o.is_ms_shipped = 0
     ) AS ol
OUTER APPLY (
        SELECT MAX(CASE WHEN LOWER(ep.name) LIKE ''%domain%''
                          OR LOWER(ep.name) LIKE ''%business%''
                          OR LOWER(ep.name) LIKE ''%subject%area%''
                          OR LOWER(ep.name) LIKE ''%classification%''
                          OR LOWER(ep.name) LIKE ''%data%category%''
                        THEN 1 ELSE 0 END) AS HasDomain,
               MAX(CASE WHEN LOWER(ep.name) LIKE ''%owner%''
                          OR LOWER(ep.name) LIKE ''%steward%''
                          OR LOWER(ep.name) LIKE ''%custodian%''
                          OR LOWER(ep.name) LIKE ''%contact%''
                        THEN 1 ELSE 0 END) AS HasOwner
        FROM sys.extended_properties AS ep
        WHERE ep.class = 1
          AND ep.major_id = ol.object_id
          AND ep.minor_id = 0
          AND ep.value IS NOT NULL
          AND LTRIM(RTRIM(CONVERT(nvarchar(4000), ep.value))) <> ''''
     ) AS p;';

IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5
BEGIN
    /* Azure SQL Database: only the current database is reachable. */
    BEGIN TRY
        EXEC sys.sp_executesql @Stmt;
    END TRY
    BEGIN CATCH
        /* Current database could not be read; it is simply not counted. */
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName sysname;
    DECLARE @Exec   nvarchar(400);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Exec = QUOTENAME(@DbName) + N'.sys.sp_executesql';

        BEGIN TRY
            EXEC @Exec @Stmt;
        END TRY
        BEGIN CATCH
            /* Databases that cannot be read are skipped rather than failing the audit. */
        END CATCH

        FETCH NEXT FROM db_cur INTO @DbName;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount int = (SELECT COUNT(*)                       FROM #TagCoverage);
DECLARE @Total   int = (SELECT ISNULL(SUM(TotalObjects), 0)   FROM #TagCoverage);
DECLARE @Domain  int = (SELECT ISNULL(SUM(DomainTagged), 0)   FROM #TagCoverage);
DECLARE @Owner   int = (SELECT ISNULL(SUM(OwnerTagged),  0)   FROM #TagCoverage);
DECLARE @Full    int = (SELECT ISNULL(SUM(FullyTagged),  0)   FROM #TagCoverage);

DECLARE @Pct decimal(5, 2) =
    CASE WHEN @Total = 0 THEN CONVERT(decimal(5, 2), 0)
         ELSE CONVERT(decimal(5, 2), (@Full * 100.0) / @Total)
    END;

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(
        STUFF((SELECT N', ' + t.DatabaseName
               FROM #TagCoverage AS t
               ORDER BY t.DatabaseName
               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
        N'None');

DECLARE @Score   int;
DECLARE @Result  nvarchar(20);
DECLARE @Finding nvarchar(max);

IF @Total = 0
BEGIN
    SET @Score  = 0;
    SET @Result = N'Fail';
    SET @Finding = N'No user tables or views were found in '
                 + CONVERT(nvarchar(10), @DbCount)
                 + N' accessible user database(s); no business-domain or owner classification could be evidenced.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Pct >= 90 THEN 3
                      WHEN @Pct >= 60 THEN 2
                      WHEN @Pct >  0  THEN 1
                      ELSE 0
                 END;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding = CONVERT(nvarchar(10), @Full) + N' of ' + CONVERT(nvarchar(10), @Total)
                 + N' user tables/views (' + CONVERT(nvarchar(10), @Pct) + N'%) across '
                 + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) carry BOTH a business-domain/classification extended property and an owner/steward extended property. '
                 + CONVERT(nvarchar(10), @Domain) + N' object(s) carry a domain/classification tag and '
                 + CONVERT(nvarchar(10), @Owner)  + N' object(s) carry an owner/steward tag.';
END

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;