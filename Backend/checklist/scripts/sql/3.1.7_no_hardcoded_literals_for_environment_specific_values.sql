-- Checklist: No hardcoded literals for environment-specific values
-- Scope: DATABASE
-- Scoring: 3: No hardcoded literals found. 2: 1-3 instances found. 1: 4-10 instances found. 0: >10 instances found.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @MatchCount INT = 0;
DECLARE @MatchList NVARCHAR(MAX) = '';

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    SELECT @MatchCount = COUNT(*), @MatchList = ISNULL(STRING_AGG(o.name, '',''), ''None'')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND (
        m.definition LIKE ''%Data Source=%'' OR
        m.definition LIKE ''%Initial Catalog=%'' OR
        m.definition LIKE ''%server\%'' OR
        m.definition LIKE ''%C:\%'' OR
        m.definition LIKE ''%http://%'' OR
        m.definition LIKE ''%DEV%'' OR
        m.definition LIKE ''%PROD%'' OR
        m.definition LIKE ''%QA%'' OR
        m.definition LIKE ''%TEST%'' OR
        m.definition LIKE ''%STG%'' OR
        m.definition LIKE ''%UAT%''
      );';
    EXEC sp_executesql @Sql, N'@MatchCount INT OUTPUT, @MatchList NVARCHAR(MAX) OUTPUT', @MatchCount OUTPUT, @MatchList OUTPUT;
    
    IF @MatchCount = 0 SET @Score = 3;
    ELSE IF @MatchCount <= 3 SET @Score = 2;
    ELSE IF @MatchCount <= 10 SET @Score = 1;
    ELSE SET @Score = 0;
    
    SET @Finding = CASE WHEN @MatchCount = 0 THEN 'No hardcoded literals found' ELSE 'Found in: ' + @MatchList END;
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
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
            SET @MatchCount = 0;
            SET @MatchList = '';
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            SELECT @MatchCount = COUNT(*), @MatchList = ISNULL(STRING_AGG(o.name, '',''), ''None'')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.is_ms_shipped = 0
              AND (
                m.definition LIKE ''%Data Source=%'' OR
                m.definition LIKE ''%Initial Catalog=%'' OR
                m.definition LIKE ''%server\%'' OR
                m.definition LIKE ''%C:\%'' OR
                m.definition LIKE ''%http://%'' OR
                m.definition LIKE ''%DEV%'' OR
                m.definition LIKE ''%PROD%'' OR
                m.definition LIKE ''%QA%'' OR
                m.definition LIKE ''%TEST%'' OR
                m.definition LIKE ''%STG%'' OR
                m.definition LIKE ''%UAT%''
              );';
            EXEC sp_executesql @Sql, N'@MatchCount INT OUTPUT, @MatchList NVARCHAR(MAX) OUTPUT', @MatchCount OUTPUT, @MatchList OUTPUT;
            
            IF @MatchCount = 0 SET @Score = 3;
            ELSE IF @MatchCount <= 3 SET @Score = 2;
            ELSE IF @MatchCount <= 10 SET @Score =