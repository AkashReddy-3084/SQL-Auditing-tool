/* Checklist 7.3.3 - Right-to-erasure / rectification technically achievable
   Scope: DATABASE | Read-only catalog inspection only. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';

DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Eval') IS NOT NULL DROP TABLE #Eval;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;

CREATE TABLE #Pat (Kind CHAR(3) NOT NULL, Pat NVARCHAR(128) NOT NULL);
CREATE TABLE #Dbs (DbName SYSNAME NOT NULL PRIMARY KEY);
CREATE TABLE #Skipped (DbName SYSNAME NOT NULL PRIMARY KEY);
CREATE TABLE #Eval (
    DbName SYSNAME NOT NULL PRIMARY KEY,
    PiiTables INT NOT NULL,
    ErasureModules INT NOT NULL,
    ErasureColumns INT NOT NULL,
    CascadePaths INT NOT NULL
);
CREATE TABLE #Scored (DbName SYSNAME NOT NULL PRIMARY KEY, DbScore INT NOT NULL, Detail NVARCHAR(1000) NOT NULL);

/* Personal-data column name patterns */
INSERT INTO #Pat (Kind, Pat) VALUES
 ('PII', N'%mail%'), ('PII', N'%ssn%'), ('PII', N'%socialsecurity%'), ('PII', N'%social%security%'),
 ('PII', N'%phone%'), ('PII', N'%mobile%'), ('PII', N'%firstname%'), ('PII', N'%first%name%'),
 ('PII', N'%lastname%'), ('PII', N'%last%name%'), ('PII', N'%surname%'), ('PII', N'%fullname%'),
 ('PII', N'%dateofbirth%'), ('PII', N'%birthdate%'), ('PII', N'%dob'), ('PII', N'%passport%'),
 ('PII', N'%nationalid%'), ('PII', N'%aadhaar%'), ('PII', N'%taxid%'), ('PII', N'%address%'),
 ('PII', N'%postcode%'), ('PII', N'%zipcode%'), ('PII', N'%creditcard%'), ('PII', N'%cardnumber%'),
 ('PII', N'%customername%'), ('PII', N'%ipaddress%'), ('PII', N'%datasubject%');

/* Erasure / rectification module name patterns */
INSERT INTO #Pat (Kind, Pat) VALUES
 ('MOD', N'%erase%'), ('MOD', N'%erasure%'), ('MOD', N'%anonym%'), ('MOD', N'%pseudonym%'),
 ('MOD', N'%gdpr%'), ('MOD', N'%rtbf%'), ('MOD', N'%forget%'), ('MOD', N'%redact%'),
 ('MOD', N'%scrub%'), ('MOD', N'%obfusc%'), ('MOD', N'%purge%'), ('MOD', N'%rectif%'),
 ('MOD', N'%datasubject%'), ('MOD', N'%subjectrequest%'), ('MOD', N'%dsr[_]%');

/* Erasure-support column patterns (soft delete / anonymisation markers) */
INSERT INTO #Pat (Kind, Pat) VALUES
 ('ERC', N'%isdeleted%'), ('ERC', N'%is[_]deleted%'), ('ERC', N'%deletedon%'), ('ERC', N'%deletedat%'),
 ('ERC', N'%deleted[_]date%'), ('ERC', N'%softdelete%'), ('ERC', N'%anonymi%'), ('ERC', N'%pseudonymi%'),
 ('ERC', N'%erased%'), ('ERC', N'%purged%'), ('ERC', N'%redacted%'), ('ERC', N'%forgotten%'),
 ('ERC', N'%rectified%');

IF @IsAzureDb = 1
    INSERT INTO #Dbs (DbName) SELECT DB_NAME();
ELSE
    INSERT INTO #Dbs (DbName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @Db SYSNAME, @Sql NVARCHAR(MAX);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #Dbs;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #Eval (DbName, PiiTables, ErasureModules, ErasureColumns, CascadePaths)
SELECT @p_db,
 (SELECT COUNT(DISTINCT c.object_id)
    FROM ' + QUOTENAME(@Db) + N'.sys.columns c
    JOIN ' + QUOTENAME(@Db) + N'.sys.tables t ON t.object_id = c.object_id
   WHERE t.is_ms_shipped = 0
     AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = ''PII'' AND c.name LIKE p.Pat)),
 (SELECT COUNT(*)
    FROM ' + QUOTENAME(@Db) + N'.sys.objects o
   WHERE o.is_ms_shipped = 0
     AND o.type IN (''P'',''FN'',''IF'',''TF'',''TR'',''V'')
     AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = ''MOD'' AND o.name LIKE p.Pat))
 + (SELECT COUNT(*)
      FROM ' + QUOTENAME(@Db) + N'.sys.sql_modules m
      JOIN ' + QUOTENAME(@Db) + N'.sys.objects o2 ON o2.object_id = m.object_id
     WHERE o2.is_ms_shipped = 0
       AND (m.definition LIKE ''%gdpr%'' OR m.definition LIKE ''%anonymi%''
            OR m.definition LIKE ''%erasure%'' OR m.definition LIKE ''%right to be forgotten%'')),
 (SELECT COUNT(DISTINCT c.object_id)
    FROM ' + QUOTENAME(@Db) + N'.sys.columns c
    JOIN ' + QUOTENAME(@Db) + N'.sys.tables t ON t.object_id = c.object_id
   WHERE t.is_ms_shipped = 0
     AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = ''ERC'' AND c.name LIKE p.Pat)),
 (SELECT COUNT(*)
    FROM ' + QUOTENAME(@Db) + N'.sys.foreign_keys fk
   WHERE fk.delete_referential_action IN (1,2)
     AND EXISTS (SELECT 1
                   FROM ' + QUOTENAME(@Db) + N'.sys.columns c2
                  WHERE c2.object_id = fk.referenced_object_id
                    AND EXISTS (SELECT 1 FROM #Pat p WHERE p.Kind = ''PII'' AND c2.name LIKE p.Pat)));';

        EXEC sp_executesql @Sql, N'@p_db SYSNAME', @p_db = @Db;
    END TRY
    BEGIN CATCH
        IF NOT EXISTS (SELECT 1 FROM #Skipped WHERE DbName = @Db)
            INSERT INTO #Skipped (DbName) VALUES (@Db);
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

INSERT INTO #Scored (DbName, DbScore, Detail)
SELECT e.DbName,
       CASE
            WHEN e.PiiTables = 0 THEN 3
            WHEN e.ErasureModules > 0 AND (e.ErasureColumns > 0 OR e.CascadePaths > 0) THEN 3
            WHEN e.ErasureModules > 0 THEN 2
            WHEN e.ErasureColumns > 0 OR e.CascadePaths > 0 THEN 1
            ELSE 0
       END,
       e.DbName + N' [personal-data tables=' + CAST(e.PiiTables AS NVARCHAR(10))
         + N', erasure/rectification modules=' + CAST(e.ErasureModules AS NVARCHAR(10))
         + N', erasure-support columns=' + CAST(e.ErasureColumns AS NVARCHAR(10))
         + N', cascade/set-null FK paths=' + CAST(e.CascadePaths AS NVARCHAR(10)) + N']'
FROM #Eval e;

DECLARE @EvalCount INT = (SELECT COUNT(*) FROM #Scored);
DECLARE @SkipCount INT = (SELECT COUNT(*) FROM #Skipped);

IF @EvalCount = 0
BEGIN
    SET @Score = 0;
    SET @Result = 'Fail';
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL(STUFF((SELECT N', ' + s.DbName FROM #Scored s ORDER BY s.DbName
                                         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'None');

    SET @Score = ISNULL((SELECT MIN(s.DbScore) FROM #Scored s), 0);
    IF @SkipCount > 0 AND @Score = 3 SET @Score = 2;

    SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;

    SET @Finding = N'Inspected ' + CAST(@EvalCount AS NVARCHAR(10)) + N' database(s) for right-to-erasure / rectification capability. '
        + ISNULL(STUFF((SELECT TOP (10) N'; ' + s.Detail + N' score=' + CAST(s.DbScore AS NVARCHAR(5))
                        FROM #Scored s ORDER BY s.DbScore ASC, s.DbName ASC
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'No per-database detail available')
        + CASE WHEN @EvalCount > 10 THEN N'; (showing the 10 weakest of ' + CAST(@EvalCount AS NVARCHAR(10)) + N')' ELSE N'' END
        + CASE WHEN @SkipCount > 0 THEN N'; ' + CAST(@SkipCount AS NVARCHAR(10)) + N' database(s) could not be read and capped the score at 2.' ELSE N'' END
        + N' Overall score is the lowest database score (0=no erasure or rectification mechanism for personal data, 1=partial path only, 2=mechanism without supporting erasure path, 3=erasure/rectification technically achievable).';
END

SELECT ISNULL(@Result, 'Fail') AS Result,
       ISNULL(@Score, 0) AS Score,
       ISNULL(@DatabaseQueried, 'None') AS DatabaseQueried,
       ISNULL(@Finding, 'No database found to be queried') AS Finding;

IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;
IF OBJECT_ID('tempdb..#Eval') IS NOT NULL DROP TABLE #Eval;
IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;
IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Pat') IS NOT NULL DROP TABLE #Pat;