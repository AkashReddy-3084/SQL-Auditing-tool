SET NOCOUNT ON;

DECLARE @Result nvarchar(20) = N'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(128) = N'msdb';
DECLARE @Finding nvarchar(max);

CREATE TABLE #ArchivalPurgeJobs
(
    JobName sysname NOT NULL,
    JobEnabled bit NOT NULL,
    StepId int NOT NULL,
    StepName sysname NOT NULL
);

IF DB_ID(N'msdb') IS NULL
BEGIN
    SET @Finding = N'The msdb database is unavailable, so SQL Agent archival and purge process metadata could not be inspected.';
END
ELSE
BEGIN
    BEGIN TRY
        DECLARE @Sql nvarchar(max) = N'
            INSERT INTO #ArchivalPurgeJobs (JobName, JobEnabled, StepId, StepName)
            SELECT DISTINCT
                j.name,
                j.enabled,
                s.step_id,
                s.step_name
            FROM msdb.dbo.sysjobs AS j
            INNER JOIN msdb.dbo.sysjobsteps AS s
                ON s.job_id = j.job_id
            CROSS APPLY
            (
                SELECT
                    LOWER(COALESCE(j.name, N'''')) AS JobNameLower,
                    LOWER(COALESCE(s.step_name, N'''')) AS StepNameLower,
                    LOWER(COALESCE(s.command, N'''')) AS CommandLower
            ) AS normalized
            WHERE
                normalized.JobNameLower LIKE N''%archiv%''
                OR normalized.StepNameLower LIKE N''%archiv%''
                OR normalized.CommandLower LIKE N''%archiv%''
                OR normalized.JobNameLower LIKE N''%purge%''
                OR normalized.StepNameLower LIKE N''%purge%''
                OR normalized.CommandLower LIKE N''%purge%''
                OR normalized.JobNameLower LIKE N''%retention%''
                OR normalized.StepNameLower LIKE N''%retention%''
                OR normalized.CommandLower LIKE N''%retention%''
                OR (
                    (
                        normalized.JobNameLower LIKE N''%cleanup%''
                        OR normalized.StepNameLower LIKE N''%cleanup%''
                        OR normalized.CommandLower LIKE N''%delete%''
                    )
                    AND (
                        normalized.CommandLower LIKE N''%dateadd%''
                        OR normalized.CommandLower LIKE N''%datediff%''
                        OR normalized.CommandLower LIKE N''%older than%''
                        OR normalized.CommandLower LIKE N''%createdate%''
                        OR normalized.CommandLower LIKE N''%modifieddate%''
                    )
                );';

        EXEC sys.sp_executesql @Sql;

        DECLARE @EnabledCount int =
        (
            SELECT COUNT(DISTINCT JobName)
            FROM #ArchivalPurgeJobs
            WHERE JobEnabled = 1
        );
        DECLARE @DisabledCount int =
        (
            SELECT COUNT(DISTINCT JobName)
            FROM #ArchivalPurgeJobs
            WHERE JobEnabled = 0
        );
        DECLARE @Examples nvarchar(1200);

        SELECT @Examples = STUFF
        (
            (
                SELECT TOP (10)
                    N'; ' + QUOTENAME(matches.JobName) + N' / ' + QUOTENAME(matches.StepName)
                FROM #ArchivalPurgeJobs AS matches
                ORDER BY matches.JobEnabled DESC, matches.JobName, matches.StepId
                FOR XML PATH(N''), TYPE
            ).value(N'.', N'nvarchar(1200)'),
            1,
            2,
            N''
        );

        IF @EnabledCount > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = CONCAT(
                N'Found ', @EnabledCount, N' enabled SQL Agent job(s) with archival or age-based purge evidence',
                CASE WHEN @DisabledCount > 0 THEN CONCAT(N' and ', @DisabledCount, N' disabled matching job(s)') ELSE N'' END,
                N'. Examples: ', COALESCE(@Examples, N'none'), N'.'
            );
        END
        ELSE IF @DisabledCount > 0
        BEGIN
            SET @Score = 2;
            SET @Finding = CONCAT(
                N'Found ', @DisabledCount, N' SQL Agent job(s) with archival or age-based purge evidence, but all matching jobs are disabled. Examples: ',
                COALESCE(@Examples, N'none'), N'.'
            );
        END
        ELSE
        BEGIN
            SET @Finding = N'No SQL Agent job step was found with evidence of archival, purge, retention, or age-based deletion activity.';
        END;
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = CONCAT(N'Unable to inspect SQL Agent archival and purge metadata: ', ERROR_MESSAGE());
    END CATCH;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;