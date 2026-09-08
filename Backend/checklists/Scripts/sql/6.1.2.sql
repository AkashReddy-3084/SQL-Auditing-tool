SET NOCOUNT ON;

DECLARE @Result VARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @SysAdminCount INT = 0;
DECLARE @SysAdminList NVARCHAR(MAX) = N'';
DECLARE @DbOwnerCount INT = 0;
DECLARE @DbOwnerList NVARCHAR(MAX) = N'';
DECLARE @IsAzure BIT = 0;
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
    SET @IsAzure = 1;

/* Non-system sysadmin members (server scope; skipped on Azure SQL DB) */
IF @IsAzure = 0
BEGIN
    SELECT
        @SysAdminCount = COUNT(*),
        @SysAdminList = STRING_AGG(CAST(sp.name AS NVARCHAR(MAX)), N', ')
    FROM sys.server_role_members srm
    INNER JOIN sys.server_principals sp
        ON sp.principal_id = srm.member_principal_id
    INNER JOIN sys.server_principals rp
        ON rp.principal_id = srm.role_principal_id
    WHERE rp.name = N'sysadmin'
      AND sp.name NOT IN (N'sa')
      AND sp.name NOT LIKE N'##MS_%'
      AND sp.name NOT LIKE N'NT SERVICE\%'
      AND sp.name NOT LIKE N'NT AUTHORITY\%'
      AND sp.type IN ('S', 'U', 'G');
END

SET @SysAdminCount = ISNULL(@SysAdminCount, 0);
SET @SysAdminList = ISNULL(@SysAdminList, N'');

/* Non-system db_owner members */
IF @IsAzure = 1
BEGIN
    SELECT
        @DbOwnerCount = COUNT(*),
        @DbOwnerList = STRING_AGG(CAST(dp.name AS NVARCHAR(MAX)), N', ')
    FROM sys.database_role_members drm
    INNER JOIN sys.database_principals dp
        ON dp.principal_id = drm.member_principal_id
    INNER JOIN sys.database_principals rp
        ON rp.principal_id = drm.role_principal_id
    WHERE rp.name = N'db_owner'
      AND dp.name NOT IN (N'dbo', N'INFORMATION_SCHEMA', N'sys')
      AND dp.name NOT LIKE N'##MS_%'
      AND dp.type IN ('S', 'U', 'G', 'C', 'E', 'X');

    SET @DbOwnerCount = ISNULL(@DbOwnerCount, 0);
    SET @DbOwnerList = ISNULL(@DbOwnerList, N'');
    SET @DatabaseQueried = ISNULL(DB_NAME(), N'None');
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @Cnt INT;
    DECLARE @List NVARCHAR(MAX);
    DECLARE @DbParts NVARCHAR(MAX) = N'';
    DECLARE @QueriedParts NVARCHAR(MAX) = N'';

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases d
        WHERE d.state = 0
          AND d.is_read_only = 0
          AND d.name NOT IN (N'master', N'tempdb', N'model', N'msdb')
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Cnt = 0;
        SET @List = N'';
        SET @Sql = N'
SELECT
    @CntOut = COUNT(*),
    @ListOut = STRING_AGG(CAST(dp.name AS NVARCHAR(MAX)), N'', '')
FROM ' + QUOTENAME(@DbName) + N'.sys.database_role_members drm
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals dp
    ON dp.principal_id = drm.member_principal_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals rp
    ON rp.principal_id = drm.role_principal_id
WHERE rp.name = N''db_owner''
  AND dp.name NOT IN (N''dbo'', N''INFORMATION_SCHEMA'', N''sys'')
  AND dp.name NOT LIKE N''##MS_%''
  AND dp.type IN (''S'', ''U'', ''G'', ''C'', ''E'', ''X'');';

        BEGIN TRY
            EXEC sp_executesql
                @Sql,
                N'@CntOut INT OUTPUT, @ListOut NVARCHAR(MAX) OUTPUT',
                @CntOut = @Cnt OUTPUT,
                @ListOut = @List OUTPUT;

            SET @Cnt = ISNULL(@Cnt, 0);
            SET @List = ISNULL(@List, N'');
            SET @DbOwnerCount = @DbOwnerCount + @Cnt;

            IF @QueriedParts = N''
                SET @QueriedParts = @DbName;
            ELSE
                SET @QueriedParts = @QueriedParts + N', ' + @DbName;

            IF @Cnt > 0 AND ISNULL(@List, N'') <> N''
            BEGIN
                IF @DbParts = N''
                    SET @DbParts = @DbName + N': ' + @List;
                ELSE
                    SET @DbParts = @DbParts + N'; ' + @DbName + N': ' + @List;
            END
        END TRY
        BEGIN CATCH
            /* Skip databases that cannot be queried */
            SET @Cnt = @Cnt;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SET @DbOwnerList = ISNULL(@DbParts, N'');
    SET @DatabaseQueried = CASE
        WHEN ISNULL(@QueriedParts, N'') = N'' THEN N'None'
        ELSE @QueriedParts
    END;
END

/* Score */
IF @SysAdminCount = 0 AND @DbOwnerCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Least privilege posture looks controlled: 0 non-system sysadmin members and 0 non-system db_owner members across accessible user databases.';
END
ELSE IF @SysAdminCount = 0 AND @DbOwnerCount BETWEEN 1 AND 5
BEGIN
    SET @Score = 2;
    SET @Finding = N'No non-system sysadmin members, but ' + CAST(@DbOwnerCount AS NVARCHAR(11))
        + N' non-system db_owner member(s) found (' + LEFT(@DbOwnerList, 300)
        + N'). Review whether db_owner is required or can be replaced with narrower roles.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'Broad privilege grants detected: non-system sysadmin count='
        + CAST(@SysAdminCount AS NVARCHAR(11))
        + CASE WHEN @SysAdminList <> N'' THEN N' [' + LEFT(@SysAdminList, 200) + N']' ELSE N'' END
        + N'; non-system db_owner count='
        + CAST(@DbOwnerCount AS NVARCHAR(11))
        + CASE WHEN @DbOwnerList <> N'' THEN N' [' + LEFT(@DbOwnerList, 300) + N']' ELSE N'' END
        + N'. Apply least privilege and remove unnecessary sysadmin/db_owner memberships.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF @DatabaseQueried IS NULL OR LTRIM(RTRIM(@DatabaseQueried)) = N''
    SET @DatabaseQueried = CASE WHEN @IsAzure = 1 THEN ISNULL(DB_NAME(), N'None') ELSE N'n/a (server-level + user DBs)' END;

IF @Finding IS NULL
    SET @Finding = N'Unable to evaluate least-privilege role membership.';

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;