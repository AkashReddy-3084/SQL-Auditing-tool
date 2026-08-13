-- Checklist: Parallelism used appropriately (no unnecessary serial execution)
-- Scope: SERVER
-- Scoring: 3=Optimal (MDP>1 or 0, CostThreshold>=50, zero forced serial hints), 2=Good (MDP>1 but minor gaps), 1=Suboptimal (MDP=1 globally), 0=Poor (MDP=1 + low threshold or widespread hints)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MDP INT;
DECLARE @CostThreshold INT;
DECLARE @SerialProcCount INT = 0;

-- Get server settings
SELECT @MDP = ISNULL(CONVERT(INT, value_in_use), 0) FROM sys.configurations WHERE name = 'max degree of parallelism';
SELECT @CostThreshold = ISNULL(CONVERT(INT, value_in_use), 0) FROM sys.configurations WHERE name = 'cost threshold for parallelism';

-- Check for forced serial execution in user database procedures
CREATE TABLE #SerialProcs (DbName NVARCHAR(128), ProcName NVARCHAR(256));
DECLARE @DbName NVARCHAR(128);
DECLARE @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #SerialProcs
        SELECT ''' + @DbName + ''', QUOTENAME(OBJECT_SCHEMA_NAME(p.object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(p.object_id))
        FROM sys.procedures p
        WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%OPTION (MAXDOP 1)%''
           OR OBJECT_DEFINITION(p.object_id) LIKE ''%OPTION(MAXDOP 1)%'';';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Skip inaccessible databases
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @SerialProcCount = COUNT(*) FROM #SerialProcs;

-- Scoring logic
IF @MDP > 1 OR @MDP = 0
BEGIN
    IF @CostThreshold >= 50 AND @SerialProcCount = 0 SET @Score = 3;
    ELSE SET @Score = 2;
END
ELSE IF @MDP = 1
BEGIN
    IF @CostThreshold >= 50 AND @SerialProcCount = 0 SET @Score = 1;
    ELSE SET @Score = 0;
END
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #SerialProcs;
SELECT @Result AS Result, @Score AS Score;