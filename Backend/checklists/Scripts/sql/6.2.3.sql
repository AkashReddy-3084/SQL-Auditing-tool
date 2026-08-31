/* Checklist 6.2.3 - Always Encrypted used for highly sensitive columns where required
   Read-only. Writes only to tempdb work tables. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @MajorVersion INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
DECLARE @Unsupported BIT =
    CASE WHEN @EngineEdition IN (5, 8) THEN 0
         WHEN @MajorVersion IS NOT NULL AND @MajorVersion < 13 THEN 1
         ELSE 0 END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Patterns') IS NOT NULL DROP TABLE #Patterns;
IF OBJECT_ID('tempdb..#AEColumns') IS NOT NULL DROP TABLE #AEColumns;
IF OBJECT_ID('tempdb..#AEKeys') IS NOT NULL DROP TABLE #AEKeys;
IF OBJECT_ID('tempdb..#Sensitive') IS NOT NULL DROP TABLE #Sensitive;

CREATE TABLE #Dbs (DatabaseName sysname);
CREATE TABLE #Patterns (Pattern NVARCHAR(100));
CREATE TABLE #AEColumns (DatabaseName sysname, SchemaName sysname, TableName sysname, ColumnName sysname, EncryptionType NVARCHAR(64) NULL);
CREATE TABLE #AEKeys (DatabaseName sysname, CMKCount INT, CEKCount INT);
CREATE TABLE #Sensitive (DatabaseName sysname, SchemaName sysname, TableName sysname, ColumnName sysname, DetectionSource NVARCHAR(32), IsEncrypted BIT);

INSERT INTO #Patterns (Pattern) VALUES
 (N'%ssn%'), (N'%socialsecurity%'), (N'%social_security%'),
 (N'%creditcard%'), (N'%credit_card%'), (N'%cardnumber%'), (N'%card_no%'), (N'%cvv%'),
 (N'%passport%'), (N'%nationalid%'), (N'%national_id%'), (N'%aadhaar%'),
 (N'%taxid%'), (N'%tax_id%'), (N'%bankaccount%'), (N'%bank_account%'),
 (N'%accountnumber%'), (N'%account_number%'), (N'%iban%'), (N'%routingnumber%'),
 (N'%salary%'), (N'%password%'), (N'%passwd%'), (N'%pwdhash%'), (N'%secretkey%'),
 (N'%dateofbirth%'), (N'%date_of_birth%'), (N'%birthdate%'),
 (N'%medicalrecord%'), (N'%diagnosis%'), (N'%healthid%');

IF @EngineEdition = 5
    INSERT INTO #Dbs (DatabaseName) SELECT DB_NAME();
ELSE
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.source_database_id IS NULL
      AND d.state_desc = 'ONLINE'
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;

IF @Unsupported = 0
BEGIN
    DECLARE @db sysname, @prefix NVARCHAR(300), @sql NVARCHAR(MAX), @hasClass INT;

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #Dbs;
    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @prefix = CASE WHEN @EngineEdition = 5 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

            SET @sql = N'INSERT INTO #AEColumns (DatabaseName, SchemaName, TableName, ColumnName, EncryptionType)
SELECT @DbName, s.name, t.name, c.name, c.encryption_type_desc
FROM ' + @prefix + N'sys.columns AS c
INNER JOIN ' + @prefix + N'sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
WHERE c.encryption_type IS NOT NULL;';
            EXEC sys.sp_executesql @sql, N'@DbName sysname', @DbName = @db;

            SET @sql = N'INSERT INTO #AEKeys (DatabaseName, CMKCount, CEKCount)
SELECT @DbName,
       (SELECT COUNT(*) FROM ' + @prefix + N'sys.column_master_keys),
       (SELECT COUNT(*) FROM ' + @prefix + N'sys.column_encryption_keys);';
            EXEC sys.sp_executesql @sql, N'@DbName sysname', @DbName = @db;

            SET @sql = N'INSERT INTO #Sensitive (DatabaseName, SchemaName, TableName, ColumnName, DetectionSource, IsEncrypted)
SELECT @DbName, s.name, t.name, c.name, N''NamePattern'',
       CASE WHEN c.encryption_type IS NOT NULL THEN 1 ELSE 0 END
FROM ' + @prefix + N'sys.columns AS c
INNER JOIN ' + @prefix + N'sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND EXISTS (SELECT 1 FROM #Patterns AS p
              WHERE LOWER(c.name) COLLATE Latin1_General_CI_AS LIKE p.Pattern COLLATE Latin1_General_CI_AS);';
            EXEC sys.sp_executesql @sql, N'@DbName sysname', @DbName = @db;

            SET @hasClass = 0;
            SET @sql = N'SELECT @c = COUNT(*) FROM ' + @prefix + N'sys.all_objects WHERE name = N''sensitivity_classifications'';';
            EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @hasClass OUTPUT;

            IF @hasClass > 0
            BEGIN
                SET @sql = N'INSERT INTO #Sensitive (DatabaseName, SchemaName, TableName, ColumnName, DetectionSource, IsEncrypted)
SELECT @DbName, s.name, t.name, c.name, N''Classification'',
       CASE WHEN c.encryption_type IS NOT NULL THEN 1 ELSE 0 END
FROM ' + @prefix + N'sys.sensitivity_classifications AS sc
INNER JOIN ' + @prefix + N'sys.columns AS c ON c.object_id = sc.major_id AND c.column_id = sc.minor_id
INNER JOIN ' + @prefix + N'sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = t.schema_id
WHERE sc.class = 1;';
                EXEC sys.sp_executesql @sql, N'@DbName sysname', @DbName = @db;
            END
        END TRY
        BEGIN CATCH
            /* database not accessible or metadata permission denied - skip */
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @TotalAEColumns INT = (SELECT COUNT(*) FROM #AEColumns);
DECLARE @DbsWithAE INT = (SELECT COUNT(DISTINCT DatabaseName) FROM #AEColumns);
DECLARE @DbsWithKeys INT = (SELECT COUNT(*) FROM #AEKeys WHERE CMKCount > 0 AND CEKCount > 0);
DECLARE @SensitiveTotal INT = (SELECT COUNT(*) FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName, ColumnName FROM #Sensitive) AS x);
DECLARE @SensitiveUnprotected INT = (SELECT COUNT(*) FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName, ColumnName FROM #Sensitive WHERE IsEncrypted = 0) AS y);
DECLARE @ClassifiedCount INT = (SELECT COUNT(*) FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName, ColumnName FROM #Sensitive WHERE DetectionSource = N'Classification') AS z);
DECLARE @DbCount INT = (SELECT COUNT(*) FROM #Dbs);

DECLARE @Examples NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N'; ' + u.DatabaseName + N'.' + u.SchemaName + N'.' + u.TableName + N'.' + u.ColumnName
           FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName, ColumnName FROM #Sensitive WHERE IsEncrypted = 0) AS u
           ORDER BY u.DatabaseName, u.SchemaName, u.TableName, u.ColumnName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName FROM #Dbs AS d ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DbList IS NULL SET @DbList = N'None';
IF LEN(@DbList) > 900 SET @DbList = LEFT(@DbList, 900) + N'...';

DECLARE @Result NVARCHAR(10), @Score INT, @Finding NVARCHAR(MAX);

IF @Unsupported = 1
BEGIN
    SET @Score = 0;
    SET @Finding = N'Always Encrypted requires SQL Server 2016 (major version 13) or later. This instance reports ProductVersion '
                   + CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) + N', so no sensitive column can be protected by Always Encrypted.';
END
ELSE IF @TotalAEColumns > 0 AND @SensitiveUnprotected = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Always Encrypted is in use: ' + CAST(@TotalAEColumns AS NVARCHAR(20)) + N' encrypted column(s) across '
                   + CAST(@DbsWithAE AS NVARCHAR(20)) + N' database(s), with column master and column encryption keys present in '
                   + CAST(@DbsWithKeys AS NVARCHAR(20)) + N' database(s). All ' + CAST(@SensitiveTotal AS NVARCHAR(20))
                   + N' sensitive-candidate column(s) detected (' + CAST(@ClassifiedCount AS NVARCHAR(20))
                   + N' via sys.sensitivity_classifications) are encrypted. Databases scanned: ' + CAST(@DbCount AS NVARCHAR(20)) + N'.';
END
ELSE IF @TotalAEColumns > 0 AND @SensitiveUnprotected > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Always Encrypted is only partially applied: ' + CAST(@TotalAEColumns AS NVARCHAR(20)) + N' encrypted column(s) across '
                   + CAST(@DbsWithAE AS NVARCHAR(20)) + N' database(s), but ' + CAST(@SensitiveUnprotected AS NVARCHAR(20)) + N' of '
                   + CAST(@SensitiveTotal AS NVARCHAR(20)) + N' sensitive-candidate column(s) are NOT encrypted. Examples: '
                   + ISNULL(@Examples, N'none') + N'.';
END
ELSE IF @TotalAEColumns = 0 AND @SensitiveUnprotected > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No Always Encrypted columns exist on this instance, yet ' + CAST(@SensitiveUnprotected AS NVARCHAR(20))
                   + N' sensitive-candidate column(s) were detected (' + CAST(@ClassifiedCount AS NVARCHAR(20))
                   + N' via sys.sensitivity_classifications). Column master/encryption keys are present in '
                   + CAST(@DbsWithKeys AS NVARCHAR(20)) + N' database(s). Examples: ' + ISNULL(@Examples, N'none') + N'.';
END
ELSE IF @TotalAEColumns = 0 AND @DbsWithKeys > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Always Encrypted keys (CMK/CEK) are provisioned in ' + CAST(@DbsWithKeys AS NVARCHAR(20))
                   + N' database(s) but no column is currently encrypted, and no sensitive-candidate column was detected by classification or naming pattern across '
                   + CAST(@DbCount AS NVARCHAR(20)) + N' database(s). Confirm against the data classification standard that no column requires Always Encrypted.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'No Always Encrypted keys or encrypted columns were found across ' + CAST(@DbCount AS NVARCHAR(20))
                   + N' database(s), and no sensitive-candidate column was detected via sys.sensitivity_classifications or column naming patterns. Sensitive data is therefore unprotected by Always Encrypted and columns are not classified; verify against the data classification standard.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DbList AS DatabaseQueried,
    @Finding AS Finding;