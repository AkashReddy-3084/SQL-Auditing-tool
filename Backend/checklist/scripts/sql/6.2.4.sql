/*
    Checklist Item : 6.2.4 - Dynamic Data Masking applied to sensitive columns where appropriate
    Scope          : DATABASE (iterates every qualifying user database on the instance)
    Type           : Read-only - catalog views only, no data or configuration is modified
*/
SET NOCOUNT ON;

DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @Finding         NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);

DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
CREATE TABLE #Databases (RowId INT IDENTITY(1, 1) PRIMARY KEY, DbName SYSNAME NOT NULL);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Databases (DbName)
    SELECT DB_NAME()
    WHERE DB_ID() > 4;
END
ELSE
BEGIN
    INSERT INTO #Databases (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0                      /* ONLINE */
      AND d.source_database_id IS NULL     /* exclude snapshots */
      AND d.is_in_standby = 0
      AND d.user_access = 0                /* MULTI_USER */
      AND HAS_DBACCESS(d.name) = 1
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
    ORDER BY d.name;
END;

IF OBJECT_ID('tempdb..#SensitivePatterns') IS NOT NULL DROP TABLE #SensitivePatterns;
CREATE TABLE #SensitivePatterns (Pattern NVARCHAR(128) NOT NULL PRIMARY KEY);

INSERT INTO #SensitivePatterns (Pattern) VALUES
    (N'%ssn%'), (N'%socialsecurity%'), (N'%social_security%'),
    (N'%creditcard%'), (N'%credit_card%'), (N'%cardnumber%'), (N'%card_number%'), (N'%ccnumber%'), (N'%cvv%'),
    (N'%passport%'), (N'%nationalid%'), (N'%national_id%'),
    (N'%taxid%'), (N'%tax_id%'), (N'%vatnumber%'),
    (N'%email%'), (N'%e_mail%'),
    (N'%phonenumber%'), (N'%phone_number%'), (N'%mobilenumber%'), (N'%mobile_number%'),
    (N'%dateofbirth%'), (N'%date_of_birth%'), (N'%birthdate%'), (N'%birth_date%'),
    (N'%salary%'), (N'%compensation%'), (N'%annualincome%'),
    (N'%password%'), (N'%passwd%'), (N'%pwdhash%'), (N'%secretkey%'),
    (N'%accountnumber%'), (N'%account_number%'), (N'%bankaccount%'), (N'%bank_account%'),
    (N'%iban%'), (N'%routingnumber%'), (N'%sortcode%'),
    (N'%driverlicense%'), (N'%driverslicense%'), (N'%licensenumber%'),
    (N'%medicalrecord%'), (N'%diagnosis%'), (N'%insurancenumber%'), (N'%healthid%');

IF OBJECT_ID('tempdb..#SensitiveColumns') IS NOT NULL DROP TABLE #SensitiveColumns;
CREATE TABLE #SensitiveColumns
(
    DbName       SYSNAME        NOT NULL,
    SchemaName   SYSNAME        NOT NULL,
    TableName    SYSNAME        NOT NULL,
    ColumnName   SYSNAME        NOT NULL,
    IsMasked     BIT            NOT NULL,
    MaskFunction NVARCHAR(4000) NULL
);

/* sys.masked_columns and sys.columns.is_masked only exist where Dynamic Data Masking is supported */
DECLARE @DdmSupported BIT = CASE WHEN OBJECT_ID(N'sys.masked_columns') IS NOT NULL THEN 1 ELSE 0 END;

DECLARE @SelectMask NVARCHAR(400) =
    CASE WHEN @DdmSupported = 1
         THEN N'c.is_masked, mc.masking_function'
         ELSE N'CAST(0 AS BIT), CAST(NULL AS NVARCHAR(4000))'
    END;

DECLARE @JoinMask NVARCHAR(400) =
    CASE WHEN @DdmSupported = 1
         THEN N'LEFT JOIN sys.masked_columns AS mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id'
         ELSE N''
    END;

DECLARE @ExtraFilter NVARCHAR(400) =
    CASE WHEN @DdmSupported = 1
         THEN N'AND c.encryption_type IS NULL'
         ELSE N''
    END;

DECLARE @Stmt NVARCHAR(MAX) =
N'INSERT INTO #SensitiveColumns (DbName, SchemaName, TableName, ColumnName, IsMasked, MaskFunction)
SELECT DISTINCT DB_NAME(), s.name, t.name, c.name, ' + @SelectMask + N'
FROM sys.columns AS c
INNER JOIN sys.tables AS t ON t.object_id = c.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN #SensitivePatterns AS p ON LOWER(c.name) LIKE p.Pattern
' + @JoinMask + N'
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND c.is_computed = 0
  AND c.is_column_set = 0
  AND c.is_filestream = 0
  AND c.system_type_id NOT IN (189, 240)
  ' + @ExtraFilter + N';';

DECLARE @RowId     INT = 1;
DECLARE @MaxRowId  INT = (SELECT ISNULL(MAX(RowId), 0) FROM #Databases);
DECLARE @CurrentDb SYSNAME;
DECLARE @ExecProc  NVARCHAR(300);

WHILE @RowId <= @MaxRowId
BEGIN
    SET @CurrentDb = NULL;
    SELECT @CurrentDb = d.DbName FROM #Databases AS d WHERE d.RowId = @RowId;

    IF @CurrentDb IS NOT NULL
    BEGIN
        SET @ExecProc = QUOTENAME(@CurrentDb) + N'.sys.sp_executesql';
        EXEC @ExecProc @Stmt;
    END;

    SET @RowId = @RowId + 1;
END;

DECLARE @DbCount         INT = (SELECT COUNT(*) FROM #Databases);
DECLARE @TotalSensitive  INT = (SELECT COUNT(*) FROM #SensitiveColumns);
DECLARE @MaskedSensitive INT = (SELECT COUNT(*) FROM #SensitiveColumns WHERE IsMasked = 1);

SET @DatabaseQueried =
    ISNULL(STUFF((SELECT N', ' + d.DbName
                  FROM #Databases AS d
                  ORDER BY d.DbName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'None');

DECLARE @UnmaskedList NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) N', ' + x.DbName + N'.' + x.SchemaName + N'.' + x.TableName + N'.' + x.ColumnName
           FROM #SensitiveColumns AS x
           WHERE x.IsMasked = 0
           ORDER BY x.DbName, x.SchemaName, x.TableName, x.ColumnName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @CoveragePct DECIMAL(5, 2) =
    CASE WHEN @TotalSensitive = 0 THEN CAST(100.00 AS DECIMAL(5, 2))
         ELSE CAST(100.0 * @MaskedSensitive / @TotalSensitive AS DECIMAL(5, 2))
    END;

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Score           = 0;
    SET @Finding         = N'No database found to be queried';
END
ELSE IF @DdmSupported = 0 AND @TotalSensitive > 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Dynamic Data Masking is not available on this SQL Server instance (sys.masked_columns does not exist), yet '
                 + CAST(@TotalSensitive AS NVARCHAR(10))
                 + N' user-table column(s) matching sensitive-data naming patterns were found across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s). No masking is applied to any of them. Examples: '
                 + ISNULL(@UnmaskedList, N'(none listed)') + N'.';
END
ELSE IF @DdmSupported = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Dynamic Data Masking is not available on this SQL Server instance (sys.masked_columns does not exist), and no user-table columns in the '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) queried matched the sensitive-data naming patterns evaluated, so no masking gap was identified.';
END
ELSE IF @TotalSensitive = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No user-table columns in the ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' database(s) queried matched the sensitive-data naming patterns evaluated (SSN, credit card, email, phone, date of birth, salary, password, bank/IBAN, national or tax ID, licence, health identifiers), so no unmasked sensitive column was identified.';
END
ELSE IF @MaskedSensitive = @TotalSensitive
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@TotalSensitive AS NVARCHAR(10))
                 + N' sensitive-pattern column(s) detected across ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' database(s) have a Dynamic Data Masking function defined (100.00% coverage).';
END
ELSE IF @CoveragePct >= 75.00
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Dynamic Data Masking covers ' + CAST(@MaskedSensitive AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalSensitive AS NVARCHAR(10)) + N' sensitive-pattern column(s) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) (' + CAST(@CoveragePct AS NVARCHAR(10))
                 + N'% coverage), so masking is broadly applied but not complete. Unmasked examples: '
                 + ISNULL(@UnmaskedList, N'(none listed)') + N'.';
END
ELSE IF @MaskedSensitive > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Dynamic Data Masking covers only ' + CAST(@MaskedSensitive AS NVARCHAR(10)) + N' of '
                 + CAST(@TotalSensitive AS NVARCHAR(10)) + N' sensitive-pattern column(s) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) (' + CAST(@CoveragePct AS NVARCHAR(10))
                 + N'% coverage). Unmasked examples: ' + ISNULL(@UnmaskedList, N'(none listed)') + N'.';
END
ELSE
BEGIN
    SET @Score   = 0;
    SET @Finding = N'None of the ' + CAST(@TotalSensitive AS NVARCHAR(10))
                 + N' sensitive-pattern column(s) detected across ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' database(s) have a Dynamic Data Masking function defined (0.00% coverage), although Dynamic Data Masking is supported on this instance. Unmasked examples: '
                 + ISNULL(@UnmaskedList, N'(none listed)') + N'.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID('tempdb..#SensitiveColumns') IS NOT NULL DROP TABLE #SensitiveColumns;
IF OBJECT_ID('tempdb..#SensitivePatterns') IS NOT NULL DROP TABLE #SensitivePatterns;
IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;