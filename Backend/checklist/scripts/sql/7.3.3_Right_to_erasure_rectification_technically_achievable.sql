-- Checklist: Right-to-erasure / rectification technically achievable
-- Scope: DATABASE
-- Scoring: 3=≥95% tables have PK & no blockers; 2=≥80%; 1=≥50%; 0=<50%
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Total INT, @Compliant INT, @Blockers NVARCHAR(MAX), @Pct DECIMAL(5,2), @DbScore INT, @DbFinding NVARCHAR(MAX);
    SELECT 
        @Total = COUNT(*),
        @Compliant = SUM(CASE WHEN HasPK = 1 AND HasBlockingFK = 0 AND HasTrigger = 0 THEN 1 ELSE 0 END),
        @Blockers = STRING_AGG(CASE WHEN HasPK = 0 OR HasBlockingFK = 1 OR HasTrigger = 1 THEN TableName ELSE NULL END, '','')
    FROM (
        SELECT 
            t.name AS TableName,
            CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1) THEN 1 ELSE 0 END AS HasPK,
            CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys fk WHERE fk.referenced_object_id = t.object_id AND fk.delete_referential_action <> 2) THEN 1 ELSE 0 END AS HasBlockingFK,
            CASE WHEN EXISTS (SELECT 1 FROM sys.triggers tr WHERE tr.parent_id = t.object_id AND tr.is_disabled = 0) THEN 1 ELSE 0 END AS HasTrigger
        FROM sys.tables t
        WHERE t.is_ms_shipped = 0
    ) AS T;

    SET @Pct = CASE WHEN @Total = 0 THEN 100 ELSE (@Compliant * 100.0 / @Total) END;
    SET @DbScore = CASE WHEN @Pct >= 95 THEN 3 WHEN @Pct >= 80 THEN 2 WHEN @Pct >= 50 THEN 1 ELSE 0 END;
    SET @DbFinding = CASE 
        WHEN @Compliant = @Total AND @Total > 0 THEN ''All '' + CAST(@Total AS NVARCHAR) + '' tables support targeted erasure/rectification.''
        WHEN @Total = 0 THEN ''No user tables found.''
        ELSE CAST(@Compliant AS NVARCHAR) + ''/'' + CAST(@Total AS NVARCHAR) + '' tables compliant ('' + CAST(@Pct AS NVARCHAR) + ''%). Blockers: '' + ISNULL(@Blockers, ''None'')
    END;

    SELECT @pDbName AS DbName, @DbScore AS DbScore, @DbFinding AS Finding;
    ';
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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
            DECLARE @Total INT, @Compliant INT, @Blockers NVARCHAR(MAX), @Pct DECIMAL(5,2), @DbScore INT, @DbFinding NVARCHAR(MAX);
            SELECT 
                @Total = COUNT(*),
                @Compliant = SUM(CASE WHEN HasPK = 1 AND HasBlockingFK = 0 AND HasTrigger = 0 THEN 1 ELSE 0 END),
                @Blockers = STRING_AGG(CASE WHEN HasPK = 0 OR HasBlockingFK = 1 OR HasTrigger = 1 THEN TableName ELSE NULL END, '','')
            FROM (
                SELECT 
                    t.name AS TableName,
                    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND