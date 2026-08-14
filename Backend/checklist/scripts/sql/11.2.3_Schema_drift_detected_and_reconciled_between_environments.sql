-- Checklist: Schema drift detected and reconciled between environments
-- Scope: SERVER
-- Scoring: 0=No evidence; 1=Generic CI/CD job; 2=Drift detection job; 3=Drift reconciliation job.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;

-- Check if SQL Agent is available (On-Prem / MI). Azure SQL DB Single does not have msdb access.
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    -- Look for jobs indicating Reconciliation (Sync/Reconcile) -> Score 3
    SELECT @JobCount = COUNT(1)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
    AND (
        j.name LIKE '%Sync%' OR
        j.name LIKE '%Reconcile%' OR
        j.name LIKE '%Schema%Sync%'
    );

    IF @JobCount > 0
    BEGIN
        SET @Score = 3;
    END
    ELSE
    BEGIN
        -- Look for jobs indicating Detection only (Compare/Drift) -> Score 2
        SELECT @JobCount = COUNT(1)
        FROM msdb.dbo.sysjobs j
        WHERE j.enabled = 1
        AND (
            j.name LIKE '%Compare%' OR
            j.name LIKE '%Drift%' OR
            j.name LIKE '%Schema%Compare%'
        );

        IF @JobCount > 0
        BEGIN
            SET @Score = 2;
        END
        ELSE
        BEGIN
            -- Look for generic CI/CD/Deploy jobs -> Score 1
            SELECT @JobCount = COUNT(1)
            FROM msdb.dbo.sysjobs j
            WHERE j.enabled = 1
            AND (
                j.name LIKE '%Deploy%' OR
                j.name LIKE '%CI/CD%' OR
                j.name LIKE '%Build%'
            );

            IF @JobCount > 0
            BEGIN
                SET @Score = 1;
            END
            ELSE
            BEGIN
                SET @Score = 0;
            END
        END
    END
END
ELSE
BEGIN
    -- Fallback for Azure SQL DB (No Agent): Check for drift log tables in current DB
    -- This is weak evidence but better than nothing.
    IF EXISTS (
        SELECT 1 FROM sys.tables t
        WHERE t.name LIKE '%Drift%' OR t.name LIKE '%Schema%Log%'
    )
    BEGIN
        SET @Score = 1;
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;