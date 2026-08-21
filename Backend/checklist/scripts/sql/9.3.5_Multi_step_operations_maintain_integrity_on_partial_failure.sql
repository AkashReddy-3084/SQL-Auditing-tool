-- Checklist: Multi-step operations maintain integrity on partial failure
-- Scope: DATABASE
-- Scoring: 3=All DML procedures use transactions & TRY/CATCH; 2=Most do (>=70%); 1=Some do (>=30%); 0=Few/none do.

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate only current database
    SET @DbName = DB_NAME();
    BEGIN TRY
        SET @Sql = N'
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        SELECT
            ''' + @DbName + ''' AS DbName,
            CASE
                WHEN TotalDmlProcs = 0 THEN 3
                WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.9 THEN 3
                WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.7 THEN 2
                WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.3 THEN 1
                ELSE 0
            END AS DbScore,
            CASE
                WHEN TotalDmlProcs = 0 THEN ''No multi-step DML operations found''
                WHEN CompliantProcs = TotalDmlProcs THEN ''All DML procedures use transactions and error handling''
                ELSE ''Non-compliant procedures: '' + ISNULL(NonCompliantProcs, ''None listed'')
            END AS Finding
        FROM (
            SELECT
                COUNT(*) AS TotalDmlProcs,
                SUM(CASE WHEN (LOWER(m.definition) LIKE ''%begin tran%'' OR LOWER(m.definition) LIKE ''%begin transaction%'') AND (LOWER(m.definition) LIKE ''%try%'' AND LOWER(m.definition) LIKE ''%catch%'') THEN 1 ELSE 0 END) AS CompliantProcs,
                STRING_AGG(CASE WHEN (LOWER(m.definition) NOT LIKE ''%begin tran%'' AND LOWER(m.definition) NOT LIKE ''%begin transaction%'') OR (LOWER(m.definition) NOT LIKE ''%try%'' OR LOWER(m.definition) NOT LIKE ''%catch%'') THEN QUOTENAME(SCHEMA_NAME(p.schema_id)) + ''.'' + QUOTENAME(p.name) ELSE NULL END, '', '') WITHIN GROUP (ORDER BY p.name) AS NonCompliantProcs
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition IS NOT NULL
              AND (LOWER(m.definition) LIKE ''%insert%'' OR LOWER(m.definition) LIKE ''%update%'' OR LOWER(m.definition) LIKE ''%delete%'' OR LOWER(m.definition) LIKE ''%merge%'')
              AND p.is_ms_shipped = 0
        ) AS Stats;
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate all online user databases
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT
                ''' + @DbName + ''' AS DbName,
                CASE
                    WHEN TotalDmlProcs = 0 THEN 3
                    WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.9 THEN 3
                    WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.7 THEN 2
                    WHEN CAST(CompliantProcs AS FLOAT) / TotalDmlProcs >= 0.3 THEN 1
                    ELSE 0
                END AS DbScore,
                CASE
                    WHEN TotalDmlProcs = 0 THEN ''No multi-step DML operations found''
                    WHEN CompliantProcs = TotalDmlProcs THEN ''All DML procedures use transactions and error handling''
                    ELSE ''Non-compliant procedures: '' + ISNULL(NonCompliantProcs, ''None listed'')
                END AS Finding
            FROM (
                SELECT
                    COUNT(*) AS TotalDmlProcs,
                    SUM(CASE WHEN (LOWER(m.definition) LIKE ''%begin tran%'' OR LOWER(m.definition) LIKE ''%begin transaction%'') AND (LOWER(m.definition) LIKE ''%try%'' AND LOWER(m.definition) LIKE ''%catch%'') THEN 1 ELSE 0 END) AS CompliantProcs,
                    STRING_AGG(CASE WHEN (LOWER(m.definition) NOT LIKE ''%begin tran%'' AND LOWER(m.definition) NOT LIKE ''%begin transaction%'') OR (LOWER(m.definition) NOT LIKE ''%try%'' OR LOWER(m.definition) NOT LIKE ''%catch%'') THEN QUOTENAME(SCHEMA_NAME(p.schema_id)) + ''.'' + QUOTENAME(p.name) ELSE NULL END, '', '') WITHIN GROUP (ORDER BY p.name) AS NonCompliantProcs
                FROM sys.procedures p
                JOIN sys.sql_modules m ON p.object_id = m.object_id
                WHERE m.definition IS NOT NULL
                  AND (LOWER(m.definition) LIKE ''%insert%'' OR LOWER(m.definition) LIKE ''%update%'' OR LOWER(m.definition) LIKE ''%delete%'' OR LOWER(m.definition) LIKE ''%merge%'')
                  AND p.is_ms_shipped = 0
            ) AS Stats;
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

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'No user databases found'
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