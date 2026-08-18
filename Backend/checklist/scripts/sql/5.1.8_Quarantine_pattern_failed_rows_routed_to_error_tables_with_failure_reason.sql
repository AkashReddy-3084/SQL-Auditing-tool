-- Checklist: Quarantine pattern: failed rows routed to error tables with failure reason
-- Scope: DATABASE
-- Scoring: 0=No quarantine tables found; 1=Quarantine tables exist but lack failure reason columns; 2=Quarantine tables with failure reason columns exist but not referenced by ETL procedures; 3=Quarantine tables with failure reason columns exist and are referenced by ETL procedures.

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

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TableList NVARCHAR(MAX) = NULL;
    DECLARE @ReasonColList NVARCHAR(MAX) = NULL;
    DECLARE @HasReasonCols BIT = 0;
    DECLARE @ReferencedByProcs BIT = 0;

    SELECT @TableList = STRING_AGG(t.name, '','')
    FROM sys.tables t
    WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%failed%'';

    IF @TableList IS NOT NULL
    BEGIN
        SELECT @ReasonColList = STRING_AGG(c.name, '','')
        FROM sys.tables t
        JOIN sys.columns c ON t.object_id = c.object_id
        WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%failed%'')
          AND (c.name LIKE ''%reason%'' OR c.name LIKE ''%message%'' OR c.name LIKE ''%status%'' OR c.name LIKE ''%error%'');

        IF @ReasonColList IS NOT NULL SET @HasReasonCols = 1;

        IF EXISTS (
            SELECT 1
            FROM sys.procedures p
            CROSS APPLY sys.dm_sql_referenced_entities(p.name, ''OBJECT'') ref
            JOIN sys.tables t ON ref.referenced_id = t.object_id
            WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%failed%'')
        )
        SET @ReferencedByProcs = 1;
    END

    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';

    IF @TableList IS NULL
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No quarantine/error tables found'';
    END
    ELSE IF @HasReasonCols = 0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''Quarantine tables found ('' + @TableList + '') but lack failure reason columns'';
    END
    ELSE IF @ReferencedByProcs = 0
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = ''Quarantine tables with reason columns ('' + @TableList + '', cols: '' + @ReasonColList + '') found but not referenced by ETL procedures'';
    END
    ELSE
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''Quarantine tables ('' + @TableList + '') with reason columns ('' + @ReasonColList + '') actively referenced by ETL procedures'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TableList NVARCHAR(MAX) = NULL;
            DECLARE @ReasonColList NVARCHAR(MAX) = NULL;
            DECLARE @HasReasonCols BIT = 0;
            DECLARE @ReferencedByProcs BIT = 0;

            SELECT @TableList = STRING_AGG(t.name, '','')
            FROM sys.tables t
            WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%failed%'';

            IF @TableList IS NOT NULL
            BEGIN
                SELECT @ReasonColList = STRING_AGG(c.name, '','')
                FROM sys.tables t
                JOIN sys.columns c ON t.object_id = c.object_id
                WHERE (t.name LIKE ''%error%'' OR t.name LIKE ''%quar