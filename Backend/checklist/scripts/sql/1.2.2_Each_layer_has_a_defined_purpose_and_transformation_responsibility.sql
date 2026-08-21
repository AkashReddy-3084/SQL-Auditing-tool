-- Checklist: Each layer has a defined purpose and transformation responsibility
-- Scope: DATABASE
-- Scoring: 3=Clear layer separation (>=2 layer schemas with tables) + documentation (extended properties); 2=Layer separation (>=2 schemas with tables) but missing documentation; 1=Partial separation (1 schema or naming conventions in dbo); 0=No evidence of layered architecture.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @LayerCount INT = 0;
    DECLARE @DocCount INT = 0;
    DECLARE @LayerNames NVARCHAR(MAX) = '''';
    
    SELECT @LayerCount = COUNT(DISTINCT s.name),
           @DocCount = COUNT(DISTINCT CASE WHEN ep.name IS NOT NULL THEN s.name END),
           @LayerNames = STRING_AGG(s.name, '','') WITHIN GROUP (ORDER BY s.name)
    FROM sys.schemas s
    LEFT JOIN sys.tables t ON t.schema_id = s.schema_id
    LEFT JOIN sys.extended_properties ep ON ep.major_id = s.schema_id AND ep.minor_id = 0
    WHERE s.name IN (''staging'', ''stg'', ''ods'', ''dw'', ''mart'', ''data_warehouse'', ''stage'', ''landing'', ''bronze'', ''silver'', ''gold'')
      AND EXISTS (SELECT 1 FROM sys.tables t2 WHERE t2.schema_id = s.schema_id);
      
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = ''No layered architecture evidence found'';
    
    IF @LayerCount >= 2 AND @DocCount >= 2
        SET @DbScore = 3;
    ELSE IF @LayerCount >= 2
        SET @DbScore = 2;
    ELSE IF @LayerCount = 1
        SET @DbScore = 1;
        
    IF @DbScore >= 1
        SET @DbFinding = ''Layer schemas found: '' + ISNULL(@LayerNames, ''None'') + ''; Docs: '' + CAST(@DocCount AS NVARCHAR(10));
        
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@pDbName, @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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
            DECLARE @LayerCount INT = 0;
            DECLARE @DocCount INT = 0;
            DECLARE @LayerNames NVARCHAR(MAX) = '''';
            
            SELECT @LayerCount = COUNT(DISTINCT s.name),
                   @DocCount = COUNT(DISTINCT CASE WHEN ep.name IS NOT NULL THEN s.name END),
                   @LayerNames = STRING_AGG(s.name, '','') WITHIN GROUP (ORDER BY s.name)
            FROM sys.schemas s
            LEFT JOIN sys.tables t ON t.schema_id = s.schema_id
            LEFT JOIN sys.extended_properties ep ON ep.major_id = s.schema_id AND ep.minor_id = 0
            WHERE s.name IN (''staging'', ''stg'', ''ods'', ''dw'', ''mart'', ''data_warehouse'', ''stage'', ''landing'', ''bronze'', ''silver'', ''gold'')
              AND EXISTS (SELECT 1 FROM sys.tables t2 WHERE t2.schema_id = s.schema_id);
              
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = ''No layered architecture evidence found'';
            
            IF @LayerCount >= 2 AND @DocCount >= 2
                SET @DbScore = 3;
            ELSE IF @LayerCount >= 2
                SET @DbScore = 2;
            ELSE IF @LayerCount = 1
                SET @DbScore = 1;
                
            IF @DbScore >= 1
                SET @DbFinding = ''Layer schemas found: '' + ISNULL(@LayerNames, ''None'') + ''; Docs: '' +