-- Checklist: Environment configuration parity maintained
-- Scope: DATABASE
-- Scoring: 2=All user DBs share identical key settings (strong proxy); 1=Minor variations in some DBs; 0=Significant variations or no user DBs. (Score 3 is reserved for full cross-environment verification requiring manual review.)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);
CREATE TABLE #DbSettings (
    DbName NVARCHAR(256),
    CompatLevel INT,
    RecoveryModel INT,
    PageVerify INT,
    AutoCreateStats BIT,
    AutoUpdateStats BIT
);

INSERT INTO #DbSettings
SELECT name, compatibility_level, recovery_model, page_verify_option, is_auto_create_stats, is_auto_update_stats
FROM sys.databases
WHERE database_id > 4 AND state = 0;

DECLARE @MajorityCompat INT, @MajorityRecovery INT, @MajorityPageVerify INT, @MajorityAutoCreate BIT, @MajorityAutoUpdate BIT;
SELECT @MajorityCompat = TOP 1 CompatLevel FROM #DbSettings GROUP BY CompatLevel ORDER BY COUNT(*) DESC;
SELECT @MajorityRecovery = TOP 1 RecoveryModel FROM #DbSettings GROUP BY RecoveryModel ORDER BY COUNT(*) DESC;
SELECT @MajorityPageVerify = TOP 1 PageVerify FROM #DbSettings GROUP BY PageVerify ORDER BY COUNT(*) DESC;
SELECT @MajorityAutoCreate = TOP 1 AutoCreateStats FROM #DbSettings GROUP BY AutoCreateStats ORDER BY COUNT(*) DESC;
SELECT @MajorityAutoUpdate = TOP 1 AutoUpdateStats FROM #DbSettings GROUP BY AutoUpdateStats ORDER BY COUNT(*) DESC;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        DECLARE @DbCompat INT, @DbRecovery INT, @DbPageVerify INT, @DbAutoCreate BIT, @DbAutoUpdate BIT;
        SELECT @DbCompat = CompatLevel, @DbRecovery = RecoveryModel, @DbPageVerify = PageVerify, @DbAutoCreate = AutoCreateStats, @DbAutoUpdate = AutoUpdateStats
        FROM #DbSettings WHERE DbName = @DbName;

        DECLARE @DiffCount INT = 0;
        IF @DbCompat <> @MajorityCompat SET @DiffCount += 1;
        IF @DbRecovery <> @MajorityRecovery SET @DiffCount += 1;
        IF @DbPageVerify <> @MajorityPageVerify SET @DiffCount += 1;
        IF @DbAutoCreate <> @MajorityAutoCreate SET @DiffCount += 1;
        IF @DbAutoUpdate <> @MajorityAutoUpdate SET @DiffCount += 1;

        DECLARE @DbScore INT = 2;
        IF @DiffCount = 1 SET @DbScore = 1;
        IF @DiffCount >= 2 SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
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
DROP TABLE #DbSettings;
SELECT @Result AS Result, @Score AS Score;