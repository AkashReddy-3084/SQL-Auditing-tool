-- Checklist: Unused databases/objects/indexes cleaned up
-- Scope: DATABASE
-- Scoring: 3=No unused indexes found; 2=1-5 unused indexes; 1=6-20 unused indexes; 0=>20 unused indexes

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    DECLARE @UnusedCount INT;
    DECLARE @SampleList NVARCHAR(MAX);
    
    SELECT @UnusedCount = COUNT(1),
           @SampleList = STRING_AGG(t.name + '.' + i.name, ', ') WITHIN GROUP (ORDER BY t.name, i.name)
    FROM sys.indexes i
    JOIN sys.tables t ON i.object_id = t.object_id
    LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
    WHERE i.type_desc IN ('NONCLUSTERED', 'XML', 'SPATIAL')
      AND i.is_disabled = 0
      AND (us.index_id IS NULL OR (us.user_seeks = 0 AND us.user_scans = 0 AND us.user_lookups = 0));
      
    SET @SampleList = LEFT(@SampleList, 200);
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        @DbName,
        CASE 
            WHEN @UnusedCount = 0 THEN 3
            WHEN @UnusedCount BETWEEN 1 AND 5 THEN 2
            WHEN @UnusedCount BETWEEN 6 AND 20 THEN 1
            ELSE 0
        END,
        CASE 
            WHEN @UnusedCount = 0 THEN 'No unused indexes found'
            ELSE 'Found ' +