-- Checklist: 10.4.5 Log/rowcount reconciliation captured per ETL run
-- Scope: SERVER
-- Scoring: 3 if >=80% of evaluated runs/procedures contain rowcount/reconciliation evidence; 2 if >=50%; 1 if >=20%; 0 if <20% or no runs found.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @TotalRuns INT = 0;
DECLARE @CompliantRuns INT = 0;
DECLARE @Percentage DECIMAL(5,2) = 0;
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Score INT;
DECLARE @Result NVARCHAR(10);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: No SQL Agent/msdb. Evaluate current database procedures for logging patterns.
    SELECT 
        @TotalRuns = COUNT(*),
        @CompliantRuns = SUM(CASE 
            WHEN OBJECT_DEFINITION(p.object_id) LIKE '%row%' OR OBJECT_DEFINITION(p.object_id) LIKE '%count%' 
              OR OBJECT_DEFINITION(p.object_id) LIKE '%insert%' OR OBJECT_DEFINITION(p.object_id) LIKE '%update%' 
              OR OBJECT_DEFINITION(p.object_id) LIKE '%delete%' OR OBJECT_DEFINITION(p.object_id) LIKE '%log%' 
              OR OBJECT_DEFINITION(p.object_id) LIKE '%reconcil%' 
            THEN 1 ELSE 0 END)
    FROM sys.procedures p
    WHERE p.is_ms_shipped = 0;

    SET @Percentage = CASE WHEN @TotalRuns > 0 THEN (@CompliantRuns * 100.0) / @TotalRuns ELSE 0 END;
    SET @Finding = CONCAT('Azure SQL DB: Evaluated ', @TotalRuns, ' user procedures. ', @CompliantRuns, ' contain logging/reconciliation patterns (', CONVERT(VARCHAR(10), @Percentage), '%).');
    SET @DatabaseQueried = DB_NAME();
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Evaluate SQL Agent job history (last 30 days)
    DECLARE @CutoffDate INT = CONVERT(INT, CONVERT(VARCHAR(8), GETDATE() - 30, 112));
    
    SELECT 
        @TotalRuns = COUNT(*),
        @CompliantRuns = SUM(CASE 
            WHEN ISNULL(h.messages, '') LIKE '%row%' OR ISNULL(h.messages, '') LIKE '%count%' OR ISNULL(h.messages, '') LIKE '%inserted%' 
              OR ISNULL(h.messages, '') LIKE '%updated%' OR ISNULL(h.messages, '') LIKE '%deleted%' OR ISNULL(h.messages, '') LIKE '%reconcil%' 
              OR ISNULL(h.messages, '') LIKE '%loaded%' OR ISNULL(h.messages, '') LIKE '%processed%' OR ISNULL(h.messages, '') LIKE '%records%' 
              OR ISNULL(h.messages, '') LIKE '%rows%' 
            THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
    WHERE h.run_date >= @CutoffDate
      AND h.step_id = 0;

    SET @Percentage = CASE WHEN @TotalRuns > 0 THEN (@CompliantRuns * 100.0) / @TotalRuns ELSE 0 END;
    SET @Finding = CONCAT('Evaluated ', @TotalRuns, ' recent job runs. ', @CompliantRuns, ' contained rowcount/reconciliation evidence (', CONVERT(VARCHAR(10), @Percentage), '%).');
    SET @DatabaseQueried = 'master';
END

SET @Score = CASE 
    WHEN @TotalRuns = 0 THEN 0
    WHEN @Percentage >= 80 THEN 3
    WHEN @Percentage >= 50 THEN 2
    WHEN @Percentage >= 20 THEN 1
    ELSE 0
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;