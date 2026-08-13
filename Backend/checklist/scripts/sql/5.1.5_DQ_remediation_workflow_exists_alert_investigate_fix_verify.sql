-- Checklist: DQ remediation workflow exists (alert → investigate → fix → verify)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Partial DQ artifacts, 2=Workflow stages tracked, 3=Fully automated (capped at 2 for proxy evidence)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TableCount INT = 0;
        DECLARE @StageCols INT = 0;
        DECLARE @ProcCount INT = 0;
        DECLARE @JobCount INT = 0;

        SELECT @TableCount = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%remediation%'' OR t.name LIKE ''%alert%'' OR t.name LIKE ''%ticket%'' OR t.name LIKE ''%issue%'';

        IF @TableCount > 0
        BEGIN
            SELECT @StageCols = COUNT(DISTINCT c.name)
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%remediation%'' OR t.name LIKE ''%alert%'' OR t.name LIKE ''%ticket%'' OR t.name LIKE ''%issue%''
            AND (c.name LIKE ''%status%'' OR c.name LIKE ''%stage%'' OR c.name LIKE ''%alert%'' OR c.name LIKE ''%investigate%'' OR c.name LIKE ''%fix%'' OR c.name LIKE ''%verify%'' OR c.name LIKE ''%resolution%'');
        END

        SELECT @ProcCount = COUNT(*) FROM sys.procedures p
        WHERE p.name LIKE ''%dq%'' OR p.name LIKE ''%remediation%'' OR p.name LIKE ''%alert%'';

        IF OBJECT_ID(''msdb.dbo.sysjobs'') IS NOT NULL
        BEGIN
            SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs j
            WHERE j.name LIKE ''%dq%'' OR j.name LIKE ''%remediation%'' OR j.name LIKE ''%alert%'';
        END

        DECLARE @DbScore INT = 0;
        IF @TableCount = 0 AND @ProcCount = 0 AND @JobCount = 0 SET @DbScore = 0;
        ELSE IF @TableCount > 0 AND @StageCols >= 4 AND @ProcCount > 0 SET @DbScore = 3;
        ELSE IF @TableCount > 0 AND @StageCols >= 2 SET @DbScore = 2;
        ELSE IF @TableCount > 0 OR @ProcCount > 0 OR @JobCount > 0 SET @DbScore = 1;

        IF @DbScore > 2 SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (@pDbName, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(256)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.