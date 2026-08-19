-- Checklist: XACT_ABORT / transaction state handling correct on error
-- Scope: DATABASE
-- Scoring: 3 = 100% compliant; 2 = >80% compliant; 1 = >50% compliant; 0 = <=50% compliant

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(),
        CASE 
            WHEN COUNT(*) = 0 THEN 3 
            WHEN COUNT(*) = 0 THEN 3 -- No procs = compliant
            WHEN CAST(COUNT(CASE WHEN (m.definition LIKE '%XACT_ABORT%ON%' OR m.definition LIKE '%BEGIN TRY%') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) >= 1.0 THEN 3
            WHEN CAST(COUNT(CASE WHEN (m.definition LIKE '%XACT_ABORT%ON%' OR m.definition LIKE '%BEGIN TRY%') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
            WHEN CAST(COUNT(CASE WHEN (m.definition LIKE '%XACT_ABORT%ON%' OR m.definition LIKE '%BEGIN TRY%') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.5 THEN 1
            ELSE 0 
        END,
        CASE 
            WHEN COUNT(*) = 0 THEN 'No stored procedures found'
            ELSE 'Non-compliant procs: ' + ISNULL(STRING_AGG(CASE WHEN NOT (m.definition LIKE '%XACT_ABORT%ON%' OR m.definition LIKE '%BEGIN TRY%') THEN QUOTENAME(s.name) + '.' + QUOTENAME(p.name) END, ', '), 'None')
        END
    FROM sys.procedures p
    JOIN sys.sql_modules m ON p.object_id = m.object_id
    JOIN sys.schemas s ON p.schema_id = s.schema_id;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT 
                @p_Db,
                CASE 
                    WHEN COUNT(*) = 0 THEN 3 
                    WHEN CAST(COUNT(CASE WHEN (m.definition LIKE ''%XACT_ABORT%ON%'' OR m.definition LIKE ''%BEGIN TRY%'') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) >= 1.0 THEN 3
                    WHEN CAST(COUNT(CASE WHEN (m.definition LIKE ''%XACT_ABORT%ON%'' OR m.definition LIKE ''%BEGIN TRY%'') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.8 THEN 2
                    WHEN CAST(COUNT(CASE WHEN (m.definition LIKE ''%XACT_ABORT%ON%'' OR m.definition LIKE ''%BEGIN TRY%'') THEN 1 END) AS FLOAT) / NULLIF(COUNT(*), 0) > 0.5 THEN 1
                    ELSE 0 
                END,
                CASE 
                    WHEN COUNT(*) = 0 THEN ''No stored procedures found''
                    ELSE ''Non-compliant procs: '' + ISNULL(STRING_AGG(CASE WHEN NOT (m.definition LIKE ''%XACT_ABORT%ON%'' OR m.definition LIKE ''%BEGIN TRY%'') THEN QUOTENAME(s.name) + ''.'' + QUOTENAME(p.name) END, '', ''), ''None'')
                END
                FROM ' + QUOTENAME(@DbName) + N'.sys.procedures p
                JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules m ON p.object_id = m.object_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON p.schema_id = s.schema_id;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;