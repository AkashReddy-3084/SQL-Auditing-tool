-- Checklist: SET NOCOUNT ON and appropriate SET options in procedures
-- Scope: DATABASE
-- Scoring: 3: 100% of procedures contain SET NOCOUNT ON. 2: >=90% contain it. 1: >=50% contain it. 0: <50% contain it.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

CREATE TABLE #DbsToCheck (DbName NVARCHAR(128));

IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbsToCheck (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #DbsToCheck (DbName)
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
END

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DbName FROM #DbsToCheck;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @Total INT, @Compliant INT, @NonCompliantList NVARCHAR(MAX);
        
        SELECT 
            @Total = COUNT(*),
            @Compliant = SUM(CASE WHEN PATINDEX(''%SET NOCOUNT ON%'', definition) > 0 THEN 1 ELSE 0 END)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND p.type_desc = ''SQL_STORED_PROCEDURE'';

        SELECT @NonCompliantList = STRING_AGG(p.name, '','') WITHIN GROUP (ORDER BY p.name)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
          AND p.type_desc = ''SQL_STORED_PROCEDURE''
          AND PATINDEX(''%SET NOCOUNT ON%'', definition) = 0;

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @Total = 0
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''No user-defined procedures found.'';
        END
        ELSE
        BEGIN
            IF @Compliant = @Total SET @DbScore = 3;
            ELSE IF @Compliant >= CAST(@Total * 0.9 AS INT) SET @DbScore = 2;
            ELSE IF @Compliant >= CAST(@Total * 0.5 AS INT) SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            IF @DbScore = 3
                SET @DbFinding = ''All '' + CAST(@Total AS NVARCHAR) + '' procedures contain SET NOCOUNT ON.'';
            ELSE
                SET @DbFinding = CAST(@Compliant AS NVARCHAR) + ''/'' + CAST(@Total AS NVARCHAR) + '' procedures contain SET NOCOUNT ON. Non-compliant: '' + ISNULL(@NonCompliantList, ''None'');
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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

DROP TABLE #DbsToCheck;

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No databases evaluated'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;