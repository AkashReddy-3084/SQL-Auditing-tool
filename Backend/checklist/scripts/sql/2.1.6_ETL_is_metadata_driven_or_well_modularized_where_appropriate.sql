-- Checklist: ETL is metadata-driven or well-modularized where appropriate
-- Scope: DATABASE
-- Scoring: 0: <10% show traits. 1: 10-29% show traits. 2: 30-59% show traits. 3: >=60% show traits. (Proxy evidence; full compliance requires human review.)

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
        DECLARE @TotalProcs INT = (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0);
        DECLARE @ModularProcs INT = (
            SELECT COUNT(DISTINCT p.object_id)
            FROM sys.procedures p
            JOIN sys.sql_expression_dependencies d ON p.object_id = d.referencing_id
            WHERE p.is_ms_shipped = 0
              AND d.referenced_id IN (SELECT object_id FROM sys.procedures)
        );
        DECLARE @MetadataProcs INT = (
            SELECT COUNT(DISTINCT p.object_id)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE p.is_ms_shipped = 0
              AND (
                  m.definition LIKE ''%sp_executesql%''
                  OR m.definition LIKE ''%Config%''
                  OR m.definition LIKE ''%Control%''
                  OR m.definition LIKE ''%Metadata%''
                  OR m.definition LIKE ''%Mapping%''
                  OR m.definition LIKE ''%Staging%''
              )
        );
        DECLARE @EvidenceProcs INT = @ModularProcs + @MetadataProcs;
        DECLARE @Pct FLOAT = CASE WHEN @TotalProcs > 0 THEN CAST(@EvidenceProcs AS FLOAT) / @TotalProcs * 100 ELSE 0 END;

        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = ''Total: '' + CAST(@TotalProcs AS NVARCHAR) + '', Modular: '' + CAST(@ModularProcs AS NVARCHAR) + '', Metadata/Dynamic: '' + CAST(@MetadataProcs AS NVARCHAR) + '' ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)'';

        IF @TotalProcs = 0 SET @DbScore = 0;
        ELSE IF @Pct >= 60 SET @DbScore = 3;
        ELSE IF @Pct >= 30 SET @DbScore = 2;
        ELSE IF @Pct >= 10 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor