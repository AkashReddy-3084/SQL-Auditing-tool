/* Checklist 5.1.8 - Quarantine pattern: failed rows routed to error tables with failure reason
   Scope: DATABASE. Strictly read-only - catalog metadata only, no data modification. */
SET NOCOUNT ON;

DECLARE @DatabaseQueried sysname       = N'None',
        @Total           int           = 0,
        @WithReason      int           = 0,
        @Score           int           = 0,
        @Result          nvarchar(20)  = N'Fail',
        @Finding         nvarchar(4000) = N'No database found to be queried',
        @Sample          nvarchar(2000) = NULL;

IF OBJECT_ID('tempdb..#Quarantine') IS NOT NULL
    DROP TABLE #Quarantine;

CREATE TABLE #Quarantine
(
    SchemaName   sysname NOT NULL,
    TableName    sysname NOT NULL,
    HasReason    bit     NOT NULL,
    HasTimestamp bit     NOT NULL
);

/* Only a genuine user database qualifies for this data-quality check. */
IF DB_ID() > 4
   AND DB_NAME() NOT IN (N'master', N'model', N'msdb', N'tempdb', N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
    SET @DatabaseQueried = DB_NAME();

IF @DatabaseQueried = N'None'
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    INSERT INTO #Quarantine (SchemaName, TableName, HasReason, HasTimestamp)
    SELECT
        s.name,
        t.name,
        CASE WHEN EXISTS (
                SELECT 1
                FROM sys.columns c
                WHERE c.object_id = t.object_id
                  AND (   c.name LIKE '%reason%'
                       OR c.name LIKE '%errormessage%'
                       OR c.name LIKE '%error[_]message%'
                       OR c.name LIKE '%errmsg%'
                       OR c.name LIKE '%errordesc%'
                       OR c.name LIKE '%error[_]desc%'
                       OR c.name LIKE '%errortext%'
                       OR c.name LIKE '%error[_]text%'
                       OR c.name LIKE '%errordetail%'
                       OR c.name LIKE '%failure%'
                       OR c.name LIKE '%rejectmessage%'
                       OR c.name LIKE '%reject[_]message%'
                       OR c.name LIKE '%validationmessage%'
                       OR c.name LIKE '%validation[_]message%'
                       OR c.name LIKE '%exceptionmessage%'
                       OR c.name LIKE '%exception[_]message%')
             ) THEN 1 ELSE 0 END,
        CASE WHEN EXISTS (
                SELECT 1
                FROM sys.columns c2
                WHERE c2.object_id = t.object_id
                  AND (   c2.name LIKE '%date%'
                       OR c2.name LIKE '%time%'
                       OR c2.name LIKE '%loaded%'
                       OR c2.name LIKE '%inserted%'
                       OR c2.name LIKE '%created%')
             ) THEN 1 ELSE 0 END
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s
            ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
      AND (   t.name LIKE '%quarantine%'
           OR t.name LIKE '%error%'
           OR t.name LIKE '%reject%'
           OR t.name LIKE '%exception%'
           OR t.name LIKE '%[_]err'
           OR t.name LIKE '%[_]err[_]%'
           OR t.name LIKE '%badrow%'
           OR t.name LIKE '%bad[_]row%'
           OR t.name LIKE '%invalidrow%'
           OR t.name LIKE '%invalid[_]row%'
           OR t.name LIKE '%failedrow%'
           OR t.name LIKE '%failed[_]row%'
           OR t.name LIKE '%dq[_]fail%');

    SELECT @Total      = COUNT(*),
           @WithReason = ISNULL(SUM(CAST(HasReason AS int)), 0)
    FROM #Quarantine;

    SELECT @Sample = STUFF((
            SELECT TOP (5)
                   N', ' + q.SchemaName + N'.' + q.TableName +
                   CASE WHEN q.HasReason = 1 THEN N' [reason col: yes' ELSE N' [reason col: NO' END +
                   CASE WHEN q.HasTimestamp = 1 THEN N', timestamp col: yes]' ELSE N', timestamp col: no]' END
            FROM #Quarantine AS q
            ORDER BY q.HasReason DESC, q.SchemaName, q.TableName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @Total = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No quarantine, error, reject or exception tables were found in database [' + @DatabaseQueried
                     + N']. There is no persisted destination for rows that fail validation, so failed rows are either silently discarded or the load fails outright.';
    END
    ELSE IF @WithReason = @Total
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Database [' + @DatabaseQueried + N'] contains ' + CAST(@Total AS nvarchar(10))
                     + N' quarantine/error table(s), and all ' + CAST(@WithReason AS nvarchar(10))
                     + N' carry a failure-reason column. Examples: ' + ISNULL(@Sample, N'(none)') + N'.';
    END
    ELSE IF @WithReason > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Database [' + @DatabaseQueried + N'] contains ' + CAST(@Total AS nvarchar(10))
                     + N' quarantine/error table(s) but only ' + CAST(@WithReason AS nvarchar(10))
                     + N' record a failure reason; ' + CAST(@Total - @WithReason AS nvarchar(10))
                     + N' capture failed rows without any reason column. Examples: ' + ISNULL(@Sample, N'(none)') + N'.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Database [' + @DatabaseQueried + N'] contains ' + CAST(@Total AS nvarchar(10))
                     + N' quarantine/error table(s), but none of them has a failure-reason column, so quarantined rows cannot be diagnosed or reprocessed. Examples: '
                     + ISNULL(@Sample, N'(none)') + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Quarantine') IS NOT NULL
    DROP TABLE #Quarantine;