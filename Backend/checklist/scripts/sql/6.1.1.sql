SET NOCOUNT ON;

DECLARE @EngineEdition   INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IntegratedOnly  INT           = CAST(ISNULL(SERVERPROPERTY('IsIntegratedSecurityOnly'), -1) AS INT);
DECLARE @Scope           NVARCHAR(128) = N'SERVER';
DECLARE @Context         NVARCHAR(200) = N'';
DECLARE @ExternalCount   INT           = 0;
DECLARE @WindowsCount    INT           = 0;
DECLARE @SqlCount        INT           = 0;
DECLARE @NonSqlCount     INT           = 0;
DECLARE @SqlSample       NVARCHAR(1000) = N'';
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @Finding         NVARCHAR(4000);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database exposes no server principals to a user database; evaluate contained users. */
    SET @Scope   = DB_NAME();
    SET @Context = N'Azure SQL Database - database-scoped principals in [' + DB_NAME() + N']';

    SELECT
        @ExternalCount = SUM(CASE WHEN dp.type IN ('E', 'X') THEN 1 ELSE 0 END),
        @SqlCount      = SUM(CASE WHEN dp.type = 'S' THEN 1 ELSE 0 END)
    FROM sys.database_principals AS dp
    WHERE dp.type IN ('E', 'X', 'S')
      AND dp.sid IS NOT NULL
      AND dp.is_fixed_role = 0
      AND dp.name NOT IN (N'guest', N'INFORMATION_SCHEMA', N'sys');

    SELECT @SqlSample = ISNULL(STUFF((
        SELECT TOP (10) N', ' + dp.name
        FROM sys.database_principals AS dp
        WHERE dp.type = 'S'
          AND dp.sid IS NOT NULL
          AND dp.is_fixed_role = 0
          AND dp.name NOT IN (N'guest', N'INFORMATION_SCHEMA', N'sys')
        ORDER BY dp.name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'');
END
ELSE
BEGIN
    SET @Context = N'SQL Server / Azure SQL Managed Instance - server-scoped principals';

    SELECT
        @ExternalCount = SUM(CASE WHEN sp.type IN ('E', 'X') THEN 1 ELSE 0 END),
        @WindowsCount  = SUM(CASE WHEN sp.type IN ('U', 'G') THEN 1 ELSE 0 END),
        @SqlCount      = SUM(CASE WHEN sp.type = 'S' THEN 1 ELSE 0 END)
    FROM sys.server_principals AS sp
    WHERE sp.type IN ('E', 'X', 'U', 'G', 'S')
      AND sp.is_disabled = 0
      AND sp.name NOT LIKE N'##%'
      AND sp.name NOT LIKE N'NT SERVICE\%'
      AND sp.name NOT LIKE N'NT AUTHORITY\%';

    SELECT @SqlSample = ISNULL(STUFF((
        SELECT TOP (10) N', ' + sp.name
        FROM sys.server_principals AS sp
        WHERE sp.type = 'S'
          AND sp.is_disabled = 0
          AND sp.name NOT LIKE N'##%'
        ORDER BY sp.name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'');
END

SET @ExternalCount = ISNULL(@ExternalCount, 0);
SET @WindowsCount  = ISNULL(@WindowsCount, 0);
SET @SqlCount      = ISNULL(@SqlCount, 0);
SET @NonSqlCount   = @ExternalCount + @WindowsCount;

IF @EngineEdition = 5
BEGIN
    IF @ExternalCount > 0 AND @SqlCount = 0
        SET @Score = 3;
    ELSE IF @ExternalCount > 0
        SET @Score = 2;
    ELSE
        SET @Score = 1;
END
ELSE
BEGIN
    IF @IntegratedOnly = 1 OR (@NonSqlCount > 0 AND @SqlCount = 0)
        SET @Score = 3;
    ELSE IF @NonSqlCount > 0
        SET @Score = 2;
    ELSE
        SET @Score = 1;
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

SET @Finding =
      @Context
    + N'. Entra ID / external principals: ' + CAST(@ExternalCount AS NVARCHAR(10))
    + N'; Windows principals: '             + CAST(@WindowsCount  AS NVARCHAR(10))
    + N'; enabled SQL-authentication principals: ' + CAST(@SqlCount AS NVARCHAR(10))
    + N'. Server authentication mode: '
    + CASE @IntegratedOnly
        WHEN 1 THEN N'Windows/Entra ID only (mixed mode disabled)'
        WHEN 0 THEN N'Mixed Mode (SQL authentication enabled)'
        ELSE N'not reported by this engine edition'
      END
    + CASE WHEN LEN(@SqlSample) > 0 THEN N'. SQL principals (up to 10): ' + @SqlSample ELSE N'' END
    + N'. '
    + CASE @Score
        WHEN 3 THEN N'Authentication relies on Microsoft Entra ID / integrated identities; no enabled SQL-authentication principals were found.'
        WHEN 2 THEN N'Entra ID / Windows principals are in use, but SQL-authentication principals are still enabled alongside them (partial adoption).'
        ELSE N'No Microsoft Entra ID or Windows principals were found; authentication depends entirely on SQL logins.'
      END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @Scope   AS DatabaseQueried,
    @Finding AS Finding;