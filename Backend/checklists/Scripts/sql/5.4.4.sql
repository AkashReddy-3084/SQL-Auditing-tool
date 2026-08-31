SET NOCOUNT ON;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @MajorVer int = TRY_CAST(PARSENAME(CONVERT(varchar(64), SERVERPROPERTY('ProductVersion')), 4) AS int);

/* EngineEdition 5/6/9/11 are contained single-database offerings where USE is not supported. */
DECLARE @IsSingleDbContext bit = CASE WHEN @EngineEdition IN (5, 6, 9, 11) THEN 1 ELSE 0 END;
DECLARE @HasDdm bit = CASE WHEN @EngineEdition >= 5 OR ISNULL(@MajorVer, 0) >= 13 THEN 1 ELSE 0 END;
DECLARE @HasClassification bit = CASE WHEN @EngineEdition IN (5, 6, 8, 9, 11) OR ISNULL(@MajorVer, 0) >= 15 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Sensitive') IS NOT NULL DROP TABLE #Sensitive;
IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;

CREATE TABLE #Db
(
    DatabaseName sysname NOT NULL,
    Queried      bit     NOT NULL
);

CREATE TABLE #Sensitive
(
    DatabaseName   sysname NOT NULL,
    SchemaName     sysname NOT NULL,
    TableName      sysname NOT NULL,
    ColumnName     sysname NOT NULL,
    IsMasked       bit     NOT NULL,
    IsEncrypted    bit     NOT NULL,
    IsClassified   bit     NOT NULL,
    HasFormatCheck bit     NOT NULL
);

INSERT INTO #Db (DatabaseName, Queried)
SELECT d.name, 0
FROM sys.databases AS d
WHERE d.state = 0
  AND d.source_database_id IS NULL
  AND HAS_DBACCESS(d.name) = 1
  AND (
        (@IsSingleDbContext = 1 AND d.name = DB_NAME())
     OR (@IsSingleDbContext = 0 AND d.database_id > 4)
      );

DECLARE @db sysname;
DECLARE @sql nvarchar(max);
DECLARE @maskExpr nvarchar(200);
DECLARE @encExpr nvarchar(200);
DECLARE @classExpr nvarchar(400);

SET @maskExpr  = CASE WHEN @HasDdm = 1 THEN N'CASE WHEN c.is_masked = 1 THEN 1 ELSE 0 END' ELSE N'0' END;
SET @encExpr   = CASE WHEN @HasDdm = 1 THEN N'CASE WHEN c.encryption_type IS NOT NULL THEN 1 ELSE 0 END' ELSE N'0' END;
SET @classExpr = CASE WHEN @HasClassification = 1
                      THEN N'CASE WHEN EXISTS (SELECT 1 FROM sys.sensitivity_classifications AS sc WHERE sc.major_id = c.object_id AND sc.minor_id = c.column_id) THEN 1 ELSE 0 END'
                      ELSE N'0' END;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = CASE WHEN @IsSingleDbContext = 1 THEN N'' ELSE N'USE ' + QUOTENAME(@db) + N'; ' END
                 + N'
INSERT INTO #Sensitive (DatabaseName, SchemaName, TableName, ColumnName, IsMasked, IsEncrypted, IsClassified, HasFormatCheck)
SELECT DB_NAME(), s.name, t.name, c.name,
       ' + @maskExpr + N',
       ' + @encExpr + N',
       ' + @classExpr + N',
       CASE WHEN EXISTS (
                SELECT 1
                FROM sys.check_constraints AS cc
                WHERE cc.parent_object_id = c.object_id
                  AND cc.is_disabled = 0
                  AND (cc.parent_column_id = c.column_id
                       OR CHARINDEX(QUOTENAME(c.name), cc.definition) > 0)
            ) THEN 1 ELSE 0 END
FROM sys.columns AS c
INNER JOIN sys.tables AS t ON t.object_id = c.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
  AND (
        LOWER(c.name) LIKE ''%ssn%''
     OR LOWER(c.name) LIKE ''%socialsecurity%''
     OR LOWER(c.name) LIKE ''%social_security%''
     OR LOWER(c.name) LIKE ''%aadhaar%''
     OR LOWER(c.name) LIKE ''%aadhar%''
     OR LOWER(c.name) LIKE ''%passport%''
     OR LOWER(c.name) LIKE ''%nationalid%''
     OR LOWER(c.name) LIKE ''%national_id%''
     OR LOWER(c.name) LIKE ''%creditcard%''
     OR LOWER(c.name) LIKE ''%credit_card%''
     OR LOWER(c.name) LIKE ''%cardnumber%''
     OR LOWER(c.name) LIKE ''%card_number%''
     OR LOWER(c.name) LIKE ''%cvv%''
     OR LOWER(c.name) LIKE ''%iban%''
     OR LOWER(c.name) LIKE ''%bankaccount%''
     OR LOWER(c.name) LIKE ''%bank_account%''
     OR LOWER(c.name) LIKE ''%accountnumber%''
     OR LOWER(c.name) LIKE ''%account_number%''
     OR LOWER(c.name) LIKE ''%password%''
     OR LOWER(c.name) LIKE ''%passwd%''
     OR LOWER(c.name) LIKE ''%pwdhash%''
     OR LOWER(c.name) LIKE ''%secret%''
     OR LOWER(c.name) LIKE ''%salary%''
     OR LOWER(c.name) LIKE ''%email%''
     OR LOWER(c.name) LIKE ''%phonenumber%''
     OR LOWER(c.name) LIKE ''%phone_number%''
     OR LOWER(c.name) LIKE ''%mobilenumber%''
     OR LOWER(c.name) LIKE ''%mobile_number%''
     OR LOWER(c.name) LIKE ''%dateofbirth%''
     OR LOWER(c.name) LIKE ''%date_of_birth%''
     OR LOWER(c.name) LIKE ''%birthdate%''
     OR LOWER(c.name) LIKE ''%taxid%''
     OR LOWER(c.name) LIKE ''%tax_id%''
     OR LOWER(c.name) LIKE ''%pannumber%''
     OR LOWER(c.name) LIKE ''%pan_number%''
      );';

        EXEC sys.sp_executesql @sql;

        UPDATE #Db SET Queried = 1 WHERE DatabaseName = @db;
    END TRY
    BEGIN CATCH
        UPDATE #Db SET Queried = 0 WHERE DatabaseName = @db;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @Total int, @Masked int, @Encrypted int, @Classified int, @Protected int, @WithCheck int;

SELECT @Total      = COUNT(*),
       @Masked     = SUM(CAST(IsMasked AS int)),
       @Encrypted  = SUM(CAST(IsEncrypted AS int)),
       @Classified = SUM(CAST(IsClassified AS int)),
       @Protected  = SUM(CASE WHEN IsMasked = 1 OR IsEncrypted = 1 THEN 1 ELSE 0 END),
       @WithCheck  = SUM(CAST(HasFormatCheck AS int))
FROM #Sensitive;

SET @Total      = ISNULL(@Total, 0);
SET @Masked     = ISNULL(@Masked, 0);
SET @Encrypted  = ISNULL(@Encrypted, 0);
SET @Classified = ISNULL(@Classified, 0);
SET @Protected  = ISNULL(@Protected, 0);
SET @WithCheck  = ISNULL(@WithCheck, 0);

DECLARE @DbCount int = (SELECT COUNT(*) FROM #Db WHERE Queried = 1);
DECLARE @DbSkipped int = (SELECT COUNT(*) FROM #Db WHERE Queried = 0);

DECLARE @DbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #Db
                  WHERE Queried = 1
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (10) N', ' + DatabaseName + N'.' + SchemaName + N'.' + TableName + N'.' + ColumnName
                  FROM #Sensitive
                  WHERE IsMasked = 0 AND IsEncrypted = 0
                  ORDER BY DatabaseName, SchemaName, TableName, ColumnName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Pct int = CASE WHEN @Total = 0 THEN 0 ELSE (@Protected * 100) / @Total END;

DECLARE @Score int;
DECLARE @Result varchar(20);
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No user database could be inspected (0 accessible databases; ' + CAST(@DbSkipped AS varchar(10))
                 + N' skipped due to state or permissions). Sensitive data masking and format validation could not be assessed.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'No columns matching known sensitive-data naming patterns (SSN, national ID, card/bank/IBAN, password/secret, email/phone, date of birth, tax/PAN, salary) were found across '
                 + CAST(@DbCount AS varchar(10)) + N' inspected database(s): ' + @DbList
                 + N'. Sensitive columns may exist under non-standard names; manual confirmation of the data classification inventory is recommended.';
END
ELSE IF @Pct = 100 AND @WithCheck > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@Total AS varchar(10)) + N' sensitive-named column(s) across ' + CAST(@DbCount AS varchar(10))
                 + N' database(s) are protected (' + CAST(@Masked AS varchar(10)) + N' dynamic data masked, '
                 + CAST(@Encrypted AS varchar(10)) + N' Always Encrypted, ' + CAST(@Classified AS varchar(10))
                 + N' sensitivity-classified), and ' + CAST(@WithCheck AS varchar(10))
                 + N' of them are covered by enabled CHECK constraints providing format validation.';
END
ELSE IF @Pct = 100 AND @WithCheck = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'All ' + CAST(@Total AS varchar(10)) + N' sensitive-named column(s) across ' + CAST(@DbCount AS varchar(10))
                 + N' database(s) are masked or encrypted, but no enabled CHECK constraint applies format validation to any of them.';
END
ELSE IF @Pct >= 80
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial coverage: ' + CAST(@Protected AS varchar(10)) + N' of ' + CAST(@Total AS varchar(10))
                 + N' sensitive-named column(s) (' + CAST(@Pct AS varchar(10)) + N'%) are masked or encrypted across '
                 + CAST(@DbCount AS varchar(10)) + N' database(s); ' + CAST(@WithCheck AS varchar(10))
                 + N' have format-validating CHECK constraints. Unprotected examples: ' + @Examples + N'.';
END
ELSE IF @Protected > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Weak coverage: only ' + CAST(@Protected AS varchar(10)) + N' of ' + CAST(@Total AS varchar(10))
                 + N' sensitive-named column(s) (' + CAST(@Pct AS varchar(10)) + N'%) are masked or encrypted across '
                 + CAST(@DbCount AS varchar(10)) + N' database(s); ' + CAST(@WithCheck AS varchar(10))
                 + N' have format-validating CHECK constraints. Unprotected examples: ' + @Examples + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of the ' + CAST(@Total AS varchar(10)) + N' sensitive-named column(s) found across '
                 + CAST(@DbCount AS varchar(10)) + N' database(s) are protected by dynamic data masking or Always Encrypted; '
                 + CAST(@Classified AS varchar(10)) + N' are sensitivity-classified and ' + CAST(@WithCheck AS varchar(10))
                 + N' have format-validating CHECK constraints. Examples: ' + @Examples + N'.';
END

IF @HasDdm = 0
    SET @Finding = @Finding + N' Note: this SQL Server version predates Dynamic Data Masking and Always Encrypted, so column protection could not be detected.';

IF @DbSkipped > 0
    SET @Finding = @Finding + N' ' + CAST(@DbSkipped AS varchar(10)) + N' database(s) were skipped (offline, unavailable, or insufficient permissions).';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DbList AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#Sensitive') IS NOT NULL DROP TABLE #Sensitive;
IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;