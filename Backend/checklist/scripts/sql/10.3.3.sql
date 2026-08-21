/*
================================================================================
 Checklist Item : 10.3.3 - Error/severity alerts configured (Agent alerts or equivalent)
 Area           : Monitoring & Observability
 Scope          : SERVER
 Type           : Read-only T-SQL (no DDL/DML against user or system objects)
 Description    : Enumerates SQL Server Agent alerts from msdb and verifies that
                  high-severity errors (severity 19-25) and the critical I/O /
                  corruption errors (823, 824, 825) are covered by ENABLED alerts
                  that notify at least one ENABLED operator.
 Output         : Result, Score, DatabaseQueried, Finding
================================================================================
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT            = 0;
DECLARE @DatabaseQueried NVARCHAR(256)  = N'msdb';
DECLARE @Finding         NVARCHAR(4000) = N'';

DECLARE @TotalAlerts      INT = 0;
DECLARE @EnabledAlerts    INT = 0;
DECLARE @SevCovered       INT = 0;
DECLARE @SevNotified      INT = 0;
DECLARE @IoAlerts         INT = 0;
DECLARE @EnabledOperators INT = 0;
DECLARE @MissingSev       NVARCHAR(200) = NULL;
DECLARE @UnnotifiedSev    NVARCHAR(200) = NULL;

DECLARE @MsdbName sysname     = N'msdb';
DECLARE @Sql      NVARCHAR(MAX);

IF OBJECT_ID(N'tempdb..#Alerts') IS NOT NULL DROP TABLE #Alerts;
CREATE TABLE #Alerts
(
    AlertName       sysname NULL,
    Severity        INT     NULL,
    MessageId       INT     NULL,
    IsEnabled       TINYINT NULL,
    HasNotification INT     NOT NULL DEFAULT (0)
);

IF OBJECT_ID(N'tempdb..#Operators') IS NOT NULL DROP TABLE #Operators;
CREATE TABLE #Operators
(
    OperatorName sysname NULL,
    IsEnabled    TINYINT NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: no SQL Server Agent and no msdb alert store. */
    SET @Score           = 0;
    SET @DatabaseQueried = N'master (Azure SQL Database)';
    SET @Finding         = N'MANUAL REVIEW REQUIRED: Azure SQL Database (EngineEdition 5) does not host SQL Server Agent, so msdb alert metadata (sysalerts/sysnotifications/sysoperators) does not exist and error/severity alerts cannot be enumerated from the engine. Equivalent alerting must be configured outside the database using Azure Monitor alert rules and diagnostic settings on the logical server; that configuration must be evidenced manually.';
END
ELSE
BEGIN
    BEGIN TRY
        /* Three-part names are built with QUOTENAME and executed dynamically so this
           script still parses on editions where msdb is not addressable. */
        SET @Sql = N'
            SELECT
                a.name,
                a.severity,
                a.message_id,
                a.enabled,
                CASE WHEN EXISTS (
                        SELECT 1
                        FROM ' + QUOTENAME(@MsdbName) + N'.dbo.sysnotifications AS n
                        INNER JOIN ' + QUOTENAME(@MsdbName) + N'.dbo.sysoperators AS o
                                ON o.id = n.operator_id
                        WHERE n.alert_id = a.id
                          AND o.enabled  = 1
                     ) THEN 1 ELSE 0 END
            FROM ' + QUOTENAME(@MsdbName) + N'.dbo.sysalerts AS a;';

        INSERT INTO #Alerts (AlertName, Severity, MessageId, IsEnabled, HasNotification)
        EXEC sys.sp_executesql @Sql;

        SET @Sql = N'SELECT o.name, o.enabled FROM ' + QUOTENAME(@MsdbName) + N'.dbo.sysoperators AS o;';

        INSERT INTO #Operators (OperatorName, IsEnabled)
        EXEC sys.sp_executesql @Sql;

        SELECT
            @TotalAlerts   = COUNT(*),
            @EnabledAlerts = SUM(CASE WHEN a.IsEnabled = 1 THEN 1 ELSE 0 END)
        FROM #Alerts AS a;

        SELECT @EnabledOperators = SUM(CASE WHEN o.IsEnabled = 1 THEN 1 ELSE 0 END)
        FROM #Operators AS o;

        SELECT @SevCovered = COUNT(DISTINCT a.Severity)
        FROM #Alerts AS a
        WHERE a.IsEnabled = 1
          AND a.Severity BETWEEN 19 AND 25;

        SELECT @SevNotified = COUNT(DISTINCT a.Severity)
        FROM #Alerts AS a
        WHERE a.IsEnabled = 1
          AND a.Severity BETWEEN 19 AND 25
          AND a.HasNotification = 1;

        SELECT @IoAlerts = COUNT(DISTINCT a.MessageId)
        FROM #Alerts AS a
        WHERE a.IsEnabled = 1
          AND a.MessageId IN (823, 824, 825);

        SELECT @MissingSev = STUFF((
            SELECT N',' + CAST(v.s AS NVARCHAR(2))
            FROM (VALUES (19),(20),(21),(22),(23),(24),(25)) AS v(s)
            WHERE NOT EXISTS (
                SELECT 1 FROM #Alerts AS a
                WHERE a.IsEnabled = 1 AND a.Severity = v.s)
            ORDER BY v.s
            FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'');

        SELECT @UnnotifiedSev = STUFF((
            SELECT N',' + CAST(v.s AS NVARCHAR(2))
            FROM (VALUES (19),(20),(21),(22),(23),(24),(25)) AS v(s)
            WHERE EXISTS (
                    SELECT 1 FROM #Alerts AS a
                    WHERE a.IsEnabled = 1 AND a.Severity = v.s)
              AND NOT EXISTS (
                    SELECT 1 FROM #Alerts AS a
                    WHERE a.IsEnabled = 1 AND a.Severity = v.s AND a.HasNotification = 1)
            ORDER BY v.s
            FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'');

        IF @SevCovered = 7 AND @SevNotified = 7
            SET @Score = 3;
        ELSE IF @SevCovered = 7
            SET @Score = 2;
        ELSE IF @SevCovered >= 1
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding =
              CASE
                  WHEN @Score = 3 THEN N'All seven high-severity levels (19-25) are covered by enabled SQL Server Agent alerts and every one of them notifies at least one enabled operator.'
                  WHEN @Score = 2 THEN N'All seven high-severity levels (19-25) have enabled alerts, but one or more do not notify any enabled operator, so those errors would be logged without anyone being paged.'
                  WHEN @Score = 1 THEN N'Error/severity alerting is only partially configured: enabled alerts exist for ' + CAST(@SevCovered AS NVARCHAR(10)) + N' of the 7 high-severity levels (19-25).'
                  ELSE N'No enabled SQL Server Agent alert exists for any high-severity level (19-25); fatal engine errors would raise no automated notification.'
              END
            + CASE WHEN @MissingSev IS NULL THEN N'' ELSE N' Severity levels with no enabled alert: ' + @MissingSev + N'.' END
            + CASE WHEN @UnnotifiedSev IS NULL THEN N'' ELSE N' Severity levels alerted but not notifying an enabled operator: ' + @UnnotifiedSev + N'.' END
            + N' Total alerts defined: ' + CAST(@TotalAlerts AS NVARCHAR(10))
            + N' (' + CAST(ISNULL(@EnabledAlerts, 0) AS NVARCHAR(10)) + N' enabled).'
            + N' Enabled operators: ' + CAST(ISNULL(@EnabledOperators, 0) AS NVARCHAR(10)) + N'.'
            + N' Enabled alerts covering critical I/O/corruption errors 823/824/825: ' + CAST(@IoAlerts AS NVARCHAR(10)) + N' of 3.';
    END TRY
    BEGIN CATCH
        SET @Score           = 0;
        SET @DatabaseQueried = N'msdb';
        SET @Finding         = N'MANUAL REVIEW REQUIRED: unable to enumerate SQL Server Agent alert configuration from msdb. Error '
                             + CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': ' + LEFT(ERROR_MESSAGE(), 500)
                             + N'. This usually indicates the audit login lacks access to msdb.dbo.sysalerts/sysnotifications/sysoperators, or SQL Server Agent is not installed on this edition.';
    END CATCH
END

IF OBJECT_ID(N'tempdb..#Alerts') IS NOT NULL DROP TABLE #Alerts;
IF OBJECT_ID(N'tempdb..#Operators') IS NOT NULL DROP TABLE #Operators;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;