-- Checklist: Archival/purge process exists for aged data
-- Scope: DATABASE
-- Scoring: 3=Pass (dedicated archival/purge procedures/tasks found), 2=Mostly Pass (partition functions or generic cleanup procedures found), 1=Partial Pass (only basic maintenance procedures found), 0=Fail (no relevant artifacts found)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @ProcCount INT = 0;
    DECLARE @PartCount INT = 0;
    DECLARE @MaintCount INT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = ''No relevant artifacts found'';

    SELECT @ProcCount = COUNT(*)
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE p.is_ms_shipped = 0
      AND (
        p.name LIKE ''%archive%'' OR p.name LIKE ''%purge%'' OR p.name LIKE ''%cleanup%'' OR p.name LIKE ''%retention%''
        OR m.definition LIKE ''%archive%'' OR m.definition LIKE ''%purge%'' OR m.definition LIKE ''%cleanup%'' OR m.definition LIKE ''%retention%''
      );

    SELECT @PartCount = COUNT(*) FROM sys.partition_functions;
    SELECT @MaintCount = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0 AND (name LIKE ''%index%'' OR name LIKE ''%stats%'' OR name LIKE ''%maintenance%'');

    IF @ProcCount > 0
    BEGIN
        SET @DbScore = 3;
        SELECT @DbFinding = STRING_AGG(p.name, '', '')
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND (
            p.name LIKE ''%archive%'' OR p.name LIKE ''%purge%'' OR p.name LIKE ''%cleanup%'' OR p.name LIKE ''%retention%''
            OR m.definition LIKE ''%archive%'' OR m.definition LIKE ''%purge%'' OR m.definition LIKE ''%cleanup%'' OR m.definition LIKE ''%retention%''
          );
    END
    ELSE IF @PartCount > 0
    BEGIN
        SET @DbScore = 2;
        SELECT @DbFinding = STRING_AGG(name, '', '') FROM sys.partition_functions;
    END
    ELSE IF @MaintCount > 0
    BEGIN
        SET @DbScore = 1;
        SELECT @DbFinding = STRING_AGG(name, '', '') FROM sys.procedures WHERE is_ms_shipped = 0 AND (name LIKE ''%index%'' OR name LIKE ''%stats%'' OR name LIKE ''%maintenance%'');
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @ProcCount INT = 0;
            DECLARE @PartCount INT = 0;
            DECLARE @MaintCount INT = 0;
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = ''No relevant artifacts found'';

            SELECT @ProcCount = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND (
                p.name LIKE ''%archive%'' OR p.name LIKE ''%purge%'' OR p.name LIKE ''%cleanup%'' OR p.name LIKE ''%retention%''
                OR m.definition LIKE ''%archive%'' OR m.definition LIKE ''%purge%'' OR m.definition LIKE ''%cleanup%'' OR m.definition LIKE ''%retention%''
              );

            SELECT @PartCount = COUNT(*) FROM sys.partition_functions;
            SELECT @MaintCount = COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0 AND (name LIKE ''%index%'' OR name LIKE ''%stats%'' OR name LIKE ''%maintenance%'');

            IF @ProcCount > 0
            BEGIN
                SET @DbScore = 3;
                SELECT @DbFinding = STRING_AGG(p.name, '', '')
                FROM sys.procedures p
                JOIN sys.sql_modules m ON p.object_id = m.object_id
                WHERE p.is_ms_shipped = 0
                  AND (
                    p.name LIKE ''%archive%'' OR p.name LIKE ''%purge%'' OR p.name LIKE ''%cleanup%'' OR p.name LIKE ''%retention%''
                    OR m.definition LIKE ''%archive%'' OR m.definition LIKE ''%purge%'' OR m.definition LIKE ''%cleanup%'' OR m.definition LIKE ''%retention%''
                  );
            END
            ELSE IF @PartCount > 0
            BEGIN
                SET @DbScore = 2;
                SELECT @DbFinding = STRING_AGG(name, '', '') FROM sys.partition_functions;
            END
            ELSE IF @MaintCount > 0
            BEGIN
                SET @DbScore = 1;
                SELECT @DbFinding = STRING_AGG(name, '', '') FROM sys.procedures WHERE is_ms_shipped = 0 AND (name LIKE ''%index%'' OR name LIKE ''%stats%'' OR name LIKE ''%maintenance%'');
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;