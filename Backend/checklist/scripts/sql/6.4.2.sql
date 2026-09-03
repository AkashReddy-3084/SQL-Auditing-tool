SET NOCOUNT ON;

/* Read-only audit for checklist 6.4.2 - hardcoded credentials in ETL packages, scripts and linked servers.
   Matched secret VALUES are never emitted; only object names and the matched pattern label are reported. */

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Patterns') IS NOT NULL DROP TABLE #Patterns;

CREATE TABLE #Findings
(
    Category    nvarchar(60)   NOT NULL,
    Severity    nvarchar(10)   NOT NULL,
    ObjectName  nvarchar(776)  NOT NULL,
    Detail      nvarchar(300)  NOT NULL
);

CREATE TABLE #Patterns
(
    Pattern nvarchar(200) NOT NULL,
    Label   nvarchar(100) NOT NULL
);

/* Patterns are matched against whitespace-stripped text, so spacing variations are covered. */
INSERT INTO #Patterns (Pattern, Label)
VALUES (N'%password=''%',      N'clear-text password = ''<literal>'''),
       (N'%password=n''%',     N'clear-text password = N''<literal>'''),
       (N'%pwd=%',             N'pwd= in an embedded connection string'),
       (N'%@rmtpassword=%',    N'sp_addlinkedsrvlogin @rmtpassword literal'),
       (N'%secret=''%',        N'CREATE CREDENTIAL SECRET = ''<literal>'''),
       (N'%secret=n''%',       N'CREATE CREDENTIAL SECRET = N''<literal>''');

DECLARE @IsAzureDb      bit            = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @DbScanned      int            = 0;
DECLARE @sql            nvarchar(max);
DECLARE @db             sysname;
DECLARE @HighCount      int            = 0;
DECLARE @MediumCount    int            = 0;
DECLARE @Result         nvarchar(20);
DECLARE @Score          int;
DECLARE @DatabaseQueried nvarchar(400);
DECLARE @Finding        nvarchar(max)  = N'';
DECLARE @Sample         nvarchar(max)  = N'';
DECLARE @Coverage       nvarchar(400);

IF @IsAzureDb = 1
BEGIN
    /* Azure SQL Database: no linked servers, no msdb, no cross-database access - current database only. */
    INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
    SELECT DISTINCT N'Module', N'High',
           DB_NAME() + N'.' + s.name + N'.' + o.name,
           p.Label
    FROM sys.sql_modules AS m
    INNER JOIN sys.objects AS o ON o.object_id = m.object_id
    INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
    CROSS JOIN #Patterns AS p
    WHERE o.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND REPLACE(REPLACE(REPLACE(REPLACE(m.definition, NCHAR(9), N''), NCHAR(13), N''), NCHAR(10), N''), N' ', N'')
            COLLATE Latin1_General_CI_AS LIKE p.Pattern;

    SET @DbScanned = 1;
    SET @DatabaseQueried = DB_NAME();
    SET @Coverage = N'Azure SQL Database: only T-SQL module definitions in the current database could be inspected.';
END
ELSE
BEGIN
    SET @DatabaseQueried = N'SERVER: ' + ISNULL(CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)), N'(unknown)');
    SET @Coverage = N'File-system SSIS project files and external orchestration tools are outside the engine and were not inspected.';

    /* 1. Linked servers that store a remote SQL login instead of using the caller's own credential. */
    BEGIN TRY
        INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
        SELECT N'LinkedServerLogin', N'Medium',
               N'Linked server: ' + s.name,
               N'Stored remote login mapping (uses_self_credential = 0, remote_name = '
                   + ISNULL(ll.remote_name, N'(null)') + N')'
        FROM sys.servers AS s
        INNER JOIN sys.linked_logins AS ll ON ll.server_id = s.server_id
        WHERE s.is_linked = 1
          AND ll.uses_self_credential = 0
          AND ll.remote_name IS NOT NULL;
    END TRY
    BEGIN CATCH
    END CATCH;

    /* 2. Server-level modules (server triggers). */
    BEGIN TRY
        INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
        SELECT DISTINCT N'ServerModule', N'High',
               N'Server trigger: ' + t.name,
               p.Label
        FROM sys.server_sql_modules AS m
        INNER JOIN sys.server_triggers AS t ON t.object_id = m.object_id
        CROSS JOIN #Patterns AS p
        WHERE m.definition IS NOT NULL
          AND REPLACE(REPLACE(REPLACE(REPLACE(m.definition, NCHAR(9), N''), NCHAR(13), N''), NCHAR(10), N''), N' ', N'')
                COLLATE Latin1_General_CI_AS LIKE p.Pattern;
    END TRY
    BEGIN CATCH
    END CATCH;

    /* 3. SQL Agent job step commands (ETL/maintenance scripts). */
    IF DB_ID('msdb') IS NOT NULL AND HAS_DBACCESS('msdb') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
SELECT DISTINCT N''AgentJobStep'', N''High'',
       N''Job: '' + j.name + N'' / Step '' + CAST(js.step_id AS nvarchar(10)) + N'' ('' + ISNULL(js.subsystem, N''?'') + N'')'',
       p.Label
FROM msdb.dbo.sysjobsteps AS js
INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = js.job_id
CROSS JOIN #Patterns AS p
WHERE js.command IS NOT NULL
  AND REPLACE(REPLACE(REPLACE(REPLACE(js.command, NCHAR(9), N''''), NCHAR(13), N''''), NCHAR(10), N''''), N'' '', N'''')
        COLLATE Latin1_General_CI_AS LIKE p.Pattern;';
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
        END CATCH;

        /* 4. Legacy SSIS packages stored in msdb without package-level encryption. */
        IF OBJECT_ID('msdb.dbo.sysssispackages') IS NOT NULL
           AND COL_LENGTH('msdb.dbo.sysssispackages', 'isencrypted') IS NOT NULL
        BEGIN
            BEGIN TRY
                SET @sql = N'
INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
SELECT N''SsisPackage'', N''Medium'',
       N''msdb SSIS package: '' + ISNULL(f.foldername, N''(root)'') + N''\'' + pk.name,
       N''Package stored with isencrypted = 0 - sensitive properties are not protected by package encryption''
FROM msdb.dbo.sysssispackages AS pk
LEFT JOIN msdb.dbo.sysssispackagefolders AS f ON f.folderid = pk.folderid
WHERE pk.isencrypted = 0;';
                EXEC sys.sp_executesql @sql;
            END TRY
            BEGIN CATCH
            END CATCH;
        END
    END

    /* 5. SSIS catalog environment variables that hold credentials without the sensitive flag. */
    IF DB_ID('SSISDB') IS NOT NULL AND HAS_DBACCESS('SSISDB') = 1
       AND OBJECT_ID('SSISDB.catalog.environment_variables') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @sql = N'
INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
SELECT N''SsisEnvironmentVariable'', N''High'',
       N''SSISDB environment: '' + e.name + N''\'' + v.name,
       N''Credential-named variable with sensitive = 0 - value is stored unencrypted''
FROM SSISDB.[catalog].environment_variables AS v
INNER JOIN SSISDB.[catalog].environments AS e ON e.environment_id = v.environment_id
WHERE v.sensitive = 0
  AND (v.name COLLATE Latin1_General_CI_AS LIKE N''%password%''
       OR v.name COLLATE Latin1_General_CI_AS LIKE N''%pwd%''
       OR v.name COLLATE Latin1_General_CI_AS LIKE N''%secret%''
       OR v.name COLLATE Latin1_General_CI_AS LIKE N''%credential%'');';
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
        END CATCH;
    END

    /* 6. T-SQL module definitions in every accessible online database. */
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id <> 2
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'
INSERT INTO #Findings (Category, Severity, ObjectName, Detail)
SELECT DISTINCT N''Module'', N''High'',
       @dbn + N''.'' + s.name + N''.'' + o.name,
       p.Label
FROM ' + QUOTENAME(@db) + N'.sys.sql_modules AS m
INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = m.object_id
INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
CROSS JOIN #Patterns AS p
WHERE o.is_ms_shipped = 0
  AND m.definition IS NOT NULL
  AND REPLACE(REPLACE(REPLACE(REPLACE(m.definition, NCHAR(9), N''''), NCHAR(13), N''''), NCHAR(10), N''''), N'' '', N'''')
        COLLATE Latin1_General_CI_AS LIKE p.Pattern;';
            EXEC sys.sp_executesql @sql, N'@dbn sysname', @dbn = @db;
            SET @DbScanned = @DbScanned + 1;
        END TRY
        BEGIN CATCH
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SET @DatabaseQueried = @DatabaseQueried + N' (' + CAST(@DbScanned AS nvarchar(10)) + N' database(s) scanned)';
END

SELECT @HighCount   = SUM(CASE WHEN Severity = N'High' THEN 1 ELSE 0 END),
       @MediumCount = SUM(CASE WHEN Severity = N'Medium' THEN 1 ELSE 0 END)
FROM #Findings;

SET @HighCount   = ISNULL(@HighCount, 0);
SET @MediumCount = ISNULL(@MediumCount, 0);

SELECT @Sample = @Sample + N'; ' + t.Category + N' [' + t.Severity + N'] ' + t.ObjectName + N' - ' + t.Detail
FROM (
    SELECT TOP (10) f.Category, f.Severity, f.ObjectName, f.Detail
    FROM #Findings AS f
    ORDER BY CASE f.Severity WHEN N'High' THEN 0 ELSE 1 END, f.Category, f.ObjectName
) AS t;

SET @Sample = CASE WHEN LEN(@Sample) > 2 THEN SUBSTRING(@Sample, 3, 3500) ELSE N'' END;

SET @Score = CASE
                WHEN @HighCount > 0 THEN 1
                WHEN @MediumCount > 0 THEN 2
                ELSE 3
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = CASE
        WHEN @Score = 1 THEN
            N'Hardcoded credential indicators detected: ' + CAST(@HighCount AS nvarchar(10))
            + N' high-severity and ' + CAST(@MediumCount AS nvarchar(10))
            + N' medium-severity finding(s). Examples: ' + @Sample + N'. ' + @Coverage
        WHEN @Score = 2 THEN
            N'No clear-text credentials were found in scripts, job steps or SSIS environments, but '
            + CAST(@MediumCount AS nvarchar(10))
            + N' stored-credential exposure(s) remain (linked server login mappings and/or unencrypted msdb SSIS packages): '
            + @Sample + N'. ' + @Coverage
        ELSE
            N'No hardcoded credential indicators were found in linked server login mappings, SQL Agent job step commands, msdb SSIS packages, SSISDB environment variables or T-SQL module definitions ('
            + CAST(@DbScanned AS nvarchar(10)) + N' database(s) scanned). ' + @Coverage
    END;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
IF OBJECT_ID('tempdb..#Patterns') IS NOT NULL DROP TABLE #Patterns;

SELECT @Result           AS Result,
       @Score            AS Score,
       @DatabaseQueried  AS DatabaseQueried,
       @Finding          AS Finding;