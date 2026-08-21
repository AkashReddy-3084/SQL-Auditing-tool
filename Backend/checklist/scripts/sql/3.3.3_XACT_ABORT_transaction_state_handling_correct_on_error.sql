-- Checklist: XACT_ABORT / transaction state handling correct on error
-- Scope: DATABASE
-- Scoring: 3: 0 non-compliant procedures; 2: 1-5; 1: 6-20; 0: >20 or evaluation failed

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT DB_NAME() AS DbName,
           CASE WHEN COUNT(*) = 0 THEN 3
                WHEN COUNT(*) <= 5 THEN 2
                WHEN COUNT(*) <= 20 THEN 1
                ELSE 0 END AS DbScore,
           ISNULL(NULLIF(STRING_AGG(QUOTENAME(SCHEMA_NAME(p.schema_id)) + '.' + QUOTENAME(p.name), ', '), ''), 'No non-compliant objects found') AS Finding
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    WHERE m.definition LIKE '%BEGIN TRAN%' 
      AND m.definition NOT LIKE '%XACT_ABORT%' 
      AND m.definition NOT LIKE '%XACT_STATE%';
      
    SET @DatabaseQueried = DB_NAME();
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;
    
    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''' AS DbName,
                   CASE WHEN COUNT(*) = 0 THEN 3
                        WHEN COUNT(*) <= 5 THEN 2
                        WHEN COUNT(*) <= 20 THEN 1
                        ELSE 0 END AS DbScore,
                   ISNULL(NULLIF(STRING_AGG(QUOTENAME(SCHEMA_NAME(p.schema_id)) + ''.'' + QUOTENAME(p.name), ''','''), ''''), ''No non-compliant objects found'') AS Finding
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition LIKE ''%BEGIN TRAN%'' 
              AND m.definition NOT LIKE ''%XACT_ABORT%'' 
              AND m.definition NOT LIKE ''%XACT_STATE%'';
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
    
    SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;