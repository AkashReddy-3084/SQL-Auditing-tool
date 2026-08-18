-- Checklist: Filegroups used to organize storage where applicable (SQL Server/MI)
-- Scope: DATABASE
-- Scoring: 0: Only PRIMARY filegroup exists. 1: Multiple filegroups defined but no files assigned. 2: Multiple filegroups with files, but no tables/indexes assigned to non-PRIMARY filegroups. 3: Multiple filegroups with files, and tables/indexes actively assigned to non-PRIMARY filegroups.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @fg_count INT, @file_count INT, @obj_count INT, @fg_names NVARCHAR(MAX);
    SELECT @fg_count = COUNT(*) FROM sys.filegroups;
    SELECT @fg_names = ISNULL((SELECT STRING_AGG(name, '','') FROM sys.filegroups WHERE data_space_id > 1), ''None'');
    SELECT @file_count = COUNT(*) FROM sys.database_files WHERE data_space_id > 1;
    SELECT @obj_count = COUNT(DISTINCT t.object_id) FROM sys.tables t JOIN sys.indexes i ON t.object_id = i.object_id WHERE i.data_space_id > 1;

    DECLARE @db_score INT, @db_finding NVARCHAR(MAX);
    IF @fg_count <= 1
        BEGIN SET @db_score = 0; SET @db_finding = ''Only PRIMARY filegroup exists.''; END
    ELSE IF @file_count = 0
        BEGIN SET @db_score = 1; SET @db_finding = ''Filegroups defined but unused: '' + @fg_names; END
    ELSE IF @obj_count = 0
        BEGIN SET @db_score = 2; SET @db_finding = ''Filegroups with files but no objects assigned: '' + @fg_names; END
    ELSE
        BEGIN SET @db_score = 3; SET @db_finding = ''Storage organized across filegroups: '' + @fg_names + ''. '' + CAST(@obj_count AS NVARCHAR(10)) + '' tables/indexes assigned.''; END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @db_score, @db_finding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @fg_count INT, @file_count INT, @obj_count INT, @fg_names NVARCHAR(MAX);
            SELECT @fg_count = COUNT(*) FROM sys.filegroups;
            SELECT @fg_names = ISNULL((SELECT STRING_AGG(name, '','') FROM sys.filegroups WHERE data_space_id > 1), ''None'');
            SELECT @file_count = COUNT(*) FROM sys.database_files WHERE data_space_id > 1;
            SELECT @obj_count = COUNT(DISTINCT t.object_id) FROM sys.tables t JOIN sys.indexes i ON t.object_id = i.object_id WHERE i.data_space_id > 1;

            DECLARE @db_score INT, @db_finding NVARCHAR(MAX);
            IF @fg_count <= 1
                BEGIN SET @db_score = 0; SET @db_finding = ''Only PRIMARY filegroup exists.''; END
            ELSE IF @file_count = 0
                BEGIN SET @db_score = 1; SET @db_finding = ''Filegroups defined but unused: '' + @fg_names; END
            ELSE IF @obj_count = 0
                BEGIN SET @db_score = 2; SET @db_finding = ''Filegroups with files but no objects assigned: '' + @fg_names; END
            ELSE
                BEGIN SET @db_score = 3; SET @db_finding = ''Storage organized across filegroups: '' + @fg_names + ''. '' + CAST(@obj_count AS NVARCHAR(10)) + '' tables/indexes assigned.''; END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @db_score, @db_finding);
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

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
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
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;