-- Checklist: Recovery model appropriate (Full/Simple/Bulk-logged) — SQL Server/MI
-- Scope: DATABASE
-- Scoring: 3=Full, 2=Bulk-logged, 0=Simple. Worst-case score across all databases determines overall result.
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
    DECLARE @RecoveryModel NVARCHAR(60) = DATABASEPROPERTYEX(@DbName, 'Recovery');
    
    DECLARE @DbScore INT = CASE 
        WHEN @RecoveryModel = 'FULL' THEN 3
        WHEN @RecoveryModel = 'BULK_LOGGED' THEN 2
        ELSE 0
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@DbName, @DbScore, @RecoveryModel);

    SET @DatabaseQueried = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: evaluate all online user databases
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT 
        name,
        CASE recovery_model_desc
            WHEN 'FULL' THEN 3
            WHEN 'BULK_LOGGED' THEN 2
            ELSE 0
        END,
        recovery_model_desc
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    SET @DatabaseQueried = (
        SELECT STRING_AGG(DbName, ', ')
        FROM #DbResults
    );
END

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;