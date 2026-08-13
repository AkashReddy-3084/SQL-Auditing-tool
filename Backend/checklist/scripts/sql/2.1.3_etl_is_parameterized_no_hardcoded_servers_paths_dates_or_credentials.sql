DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @TotalObjects INT = 0;
DECLARE @FlaggedObjects INT = 0;

CREATE TABLE #ETLScan (
    SourceDB NVARCHAR(256),
    ObjectType NVARCHAR(50),
    ObjectName NVARCHAR(256),
    HasHardcoded BIT
);

-- Scan user databases for stored procedures
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #ETLScan (SourceDB, ObjectType, ObjectName, HasHardcoded)
        SELECT
            DB_NAME(),
            ''Procedure'',
            p.name,
            CASE
                WHEN m.definition LIKE ''%C:\%'' OR m.definition LIKE ''%D:\%'' OR m.definition LIKE ''%\\%''
                     OR m.definition LIKE ''%sa%'' OR m.definition LIKE ''%password%'' OR m.definition LIKE ''%pwd%''
                     OR m.definition LIKE ''%''''20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]''''%''
                     OR m.definition LIKE ''%server = ''''%'' OR m.definition LIKE ''%@server = ''''%''
                THEN 1 ELSE 0
            END
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition IS NOT NULL;';
        EXEC(@Sql);
    END TRY
    BEGIN CATCH
        -- Skip databases where permissions or errors prevent scanning
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Scan SQL Agent job steps (if available on-prem/MI)
IF OBJECT_ID('msdb.dbo.sysjobsteps') IS NOT NULL
BEGIN
    INSERT INTO #ETLScan (SourceDB, ObjectType, ObjectName, HasHardcoded)
    SELECT
        'msdb',
        'JobStep',
        j.name + '.' + CAST(js.step_id AS NVARCHAR(10)),
        CASE
            WHEN js.command LIKE '%C:\%' OR js.command LIKE '%D:\%' OR js.command LIKE '%\\%'
                 OR js.command LIKE '%sa%' OR js.command LIKE '%password%' OR js.command LIKE '%pwd%'
                 OR js.command LIKE '%''20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]''%'
                 OR js.command LIKE '%server = ''%' OR js.command LIKE '%@server = ''%'
            THEN 1 ELSE 0
        END
    FROM msdb.dbo.sysjobsteps js
    JOIN msdb.dbo.sysjobs j ON js.job_id = j.job_id
    WHERE js.command IS NOT NULL;
END

SELECT @TotalObjects = COUNT(*), @FlaggedObjects = ISNULL(SUM(HasHardcoded), 0) FROM #ETLScan;

IF @TotalObjects = 0
BEGIN
    SET @Score = 0; -- No ETL artifacts found to evaluate
END
ELSE
BEGIN
    DECLARE @FlagRatio FLOAT = CAST(@FlaggedObjects AS FLOAT) / @TotalObjects;
    SET @Score = CASE
        WHEN @FlaggedObjects = 0 THEN 2 -- Capped at 2 per proxy-evidence rule
        WHEN @FlagRatio <= 0.1 THEN 2
        WHEN @FlagRatio <= 0.3 THEN 1
        ELSE 0
    END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #ETLScan;
SELECT @Result AS Result, @Score AS Score;