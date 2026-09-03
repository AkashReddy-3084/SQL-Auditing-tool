-- Checklist: SET NOCOUNT ON and appropriate SET options in procedures
-- Scope: DATABASE
-- Scoring: 3 = every user stored procedure suppresses row counts and was created with ANSI_NULLS and QUOTED_IDENTIFIER ON, or none exist; 2 = under 5% non-compliant; 1 = under 25% non-compliant; 0 = 25% or more non-compliant, or module metadata is unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Stored procedure metadata could not be read in this database';
DECLARE @Total INT = 0;
DECLARE @NoCount INT = 0;
DECLARE @Ansi INT = 0;
DECLARE @Quoted INT = 0;
DECLARE @Compliant INT = 0;
DECLARE @OffenderList NVARCHAR(MAX) = '';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Probed BIT = 0;
DECLARE @NoCountPattern NVARCHAR(30) = '%NOCOUNT ON%';

BEGIN TRY
    SELECT @Total = COUNT(*),
           @NoCount = ISNULL(SUM(CASE WHEN m.definition LIKE @NoCountPattern THEN 1 ELSE 0 END), 0),
           @Ansi = ISNULL(SUM(CASE WHEN m.uses_ansi_nulls = 1 THEN 1 ELSE 0 END), 0),
           @Quoted = ISNULL(SUM(CASE WHEN m.uses_quoted_identifier = 1 THEN 1 ELSE 0 END), 0),
           @Compliant = ISNULL(SUM(CASE WHEN m.definition LIKE @NoCountPattern
                                         AND m.uses_ansi_nulls = 1
                                         AND m.uses_quoted_identifier = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.procedures AS p
    JOIN sys.sql_modules AS m ON m.object_id = p.object_id
    WHERE p.is_ms_shipped = 0;

    SELECT @OffenderList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
                              QUOTENAME(SCHEMA_NAME(p.schema_id)) + '.' + QUOTENAME(p.name)), ', '), 400), '')
    FROM sys.procedures AS p
    JOIN sys.sql_modules AS m ON m.object_id = p.object_id
    WHERE p.is_ms_shipped = 0
      AND (m.definition IS NULL
           OR m.definition NOT LIKE @NoCountPattern
           OR m.uses_ansi_nulls = 0
           OR m.uses_quoted_identifier = 0);

    SET @Probed = 1;
END TRY
BEGIN CATCH
    SET @Probed = 0;
END CATCH

SET @Ratio = CASE WHEN @Total = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Total - @Compliant) / @Total END;

IF @Probed = 0
    SET @Score = 0;
ELSE IF @Total = 0 OR @Compliant = @Total
    SET @Score = 3;
ELSE IF @Ratio < 0.05
    SET @Score = 2;
ELSE IF @Ratio < 0.25
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Finding = CASE WHEN @Probed = 0
    THEN 'sys.procedures / sys.sql_modules could not be read in this database; VIEW DEFINITION permission is required to inspect procedure SET options.'
    WHEN @Total = 0
    THEN 'No user-defined stored procedures exist in this database, so no procedure can leave row counts or SET options misconfigured.'
    ELSE CONCAT('User stored procedures = ', @Total, '; suppressing row counts = ', @NoCount,
                '; created with ANSI_NULLS ON = ', @Ansi,
                '; created with QUOTED_IDENTIFIER ON = ', @Quoted,
                '; satisfying all three = ', @Compliant, ' (',
                CONVERT(NVARCHAR(20), CONVERT(DECIMAL(9, 2), @Ratio * 100)), '% non-compliant)',
                CASE WHEN LEN(ISNULL(@OffenderList, '')) > 0 THEN CONCAT('. Non-compliant: ', @OffenderList)
                     ELSE '' END, '.')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
