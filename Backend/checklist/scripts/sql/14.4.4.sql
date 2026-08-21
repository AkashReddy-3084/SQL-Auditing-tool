/*
    Checklist Item : 14.4.4 - MAXDOP and cost threshold for parallelism set deliberately
    Scope          : SERVER
    Type           : Read-only T-SQL (SELECT only against catalog views / DMVs)
    Output         : Result, Score, DatabaseQueried, Finding
*/

SET NOCOUNT ON;

DECLARE @MaxDopConfig      INT = NULL,
        @MaxDopRunning     INT = NULL,
        @CtfpConfig        INT = NULL,
        @CtfpRunning       INT = NULL,
        @CpuCount          INT = NULL,
        @RecommendedMaxDop INT = NULL,
        @MaxDopDeliberate  BIT = 0,
        @CtfpDeliberate    BIT = 0,
        @PendingRestart    BIT = 0,
        @MaxDopTooHigh     BIT = 0,
        @Result            NVARCHAR(20),
        @Score             INT = 0,
        @DatabaseQueried   NVARCHAR(256),
        @Finding           NVARCHAR(4000);

SET @DatabaseQueried = N'SERVER: ' + ISNULL(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), N'(unknown)');

BEGIN TRY
    SELECT @MaxDopConfig  = CONVERT(INT, c.value),
           @MaxDopRunning = CONVERT(INT, c.value_in_use)
    FROM sys.configurations AS c
    WHERE c.name = N'max degree of parallelism';

    SELECT @CtfpConfig  = CONVERT(INT, c.value),
           @CtfpRunning = CONVERT(INT, c.value_in_use)
    FROM sys.configurations AS c
    WHERE c.name = N'cost threshold for parallelism';
END TRY
BEGIN CATCH
    SET @MaxDopRunning = NULL;
    SET @CtfpRunning   = NULL;
END CATCH;

BEGIN TRY
    SELECT @CpuCount = CONVERT(INT, si.cpu_count)
    FROM sys.dm_os_sys_info AS si;
END TRY
BEGIN CATCH
    SET @CpuCount = NULL;
END CATCH;

IF @MaxDopRunning IS NULL OR @CtfpRunning IS NULL
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Unable to read the parallelism configuration from sys.configurations. '
                 + N'MAXDOP running value: ' + ISNULL(CONVERT(NVARCHAR(20), @MaxDopRunning), N'(not returned)')
                 + N'; cost threshold for parallelism running value: ' + ISNULL(CONVERT(NVARCHAR(20), @CtfpRunning), N'(not returned)')
                 + N'. This usually indicates an unsupported platform (e.g. Azure SQL Database, where these are not instance-level settings) '
                 + N'or insufficient permission to read server configuration. Manual review required.';
END
ELSE
BEGIN
    /* A value other than the shipped default is direct evidence of a deliberate change. */
    SET @MaxDopDeliberate = CASE WHEN @MaxDopRunning <> 0 THEN 1 ELSE 0 END;
    SET @CtfpDeliberate   = CASE WHEN @CtfpRunning   <> 5 THEN 1 ELSE 0 END;

    IF (@MaxDopConfig IS NOT NULL AND @MaxDopConfig <> @MaxDopRunning)
       OR (@CtfpConfig IS NOT NULL AND @CtfpConfig <> @CtfpRunning)
        SET @PendingRestart = 1;

    IF @CpuCount IS NOT NULL
        SET @RecommendedMaxDop = CASE WHEN @CpuCount <= 8 THEN @CpuCount ELSE 8 END;

    IF @MaxDopDeliberate = 1 AND @RecommendedMaxDop IS NOT NULL AND @MaxDopRunning > @RecommendedMaxDop
        SET @MaxDopTooHigh = 1;

    SET @Finding = N'MAXDOP running value = ' + CONVERT(NVARCHAR(20), @MaxDopRunning)
                 + N' (configured = ' + ISNULL(CONVERT(NVARCHAR(20), @MaxDopConfig), N'n/a')
                 + N', default = 0); cost threshold for parallelism running value = ' + CONVERT(NVARCHAR(20), @CtfpRunning)
                 + N' (configured = ' + ISNULL(CONVERT(NVARCHAR(20), @CtfpConfig), N'n/a')
                 + N', default = 5). Logical CPUs visible to the instance: '
                 + ISNULL(CONVERT(NVARCHAR(20), @CpuCount), N'(unavailable)')
                 + ISNULL(N'; recommended MAXDOP ceiling = ' + CONVERT(NVARCHAR(20), @RecommendedMaxDop), N'')
                 + N'. ';

    IF @MaxDopDeliberate = 1 AND @CtfpDeliberate = 1 AND @MaxDopTooHigh = 0 AND @PendingRestart = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = @Finding
                     + N'Both parallelism settings have been moved off their defaults and the MAXDOP value is within the '
                     + N'recommended ceiling for the available CPU count, so parallelism has been tuned deliberately.';
    END
    ELSE IF @MaxDopDeliberate = 0 AND @CtfpDeliberate = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = @Finding
                     + N'Both settings remain at their shipped defaults (MAXDOP = 0 means unlimited parallelism and a cost '
                     + N'threshold of 5 lets trivial queries go parallel), indicating parallelism has never been tuned for this workload.';
    END
    ELSE
    BEGIN
        SET @Score   = 2;
        SET @Finding = @Finding + N'Partial configuration: '
                     + CASE WHEN @MaxDopDeliberate = 0
                            THEN N'MAXDOP is still at the default of 0 (unlimited parallelism). ' ELSE N'' END
                     + CASE WHEN @CtfpDeliberate = 0
                            THEN N'Cost threshold for parallelism is still at the default of 5. ' ELSE N'' END
                     + CASE WHEN @MaxDopTooHigh = 1
                            THEN N'MAXDOP (' + CONVERT(NVARCHAR(20), @MaxDopRunning) + N') exceeds the recommended ceiling of '
                                 + CONVERT(NVARCHAR(20), @RecommendedMaxDop) + N' for ' + CONVERT(NVARCHAR(20), @CpuCount)
                                 + N' logical CPUs. ' ELSE N'' END
                     + CASE WHEN @PendingRestart = 1
                            THEN N'A configured value differs from the running value, so a change has not yet taken effect. ' ELSE N'' END
                     + N'Parallelism is only partly tuned.';
    END
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;