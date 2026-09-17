-- Checklist: Dependencies documented (linked servers, cross-database references)
-- Scope: DATABASE
-- Scoring: 3 = no dependency evidence exists, or dependencies have documented objects with no ambiguous references; 2 = dependency and documentation evidence exist, or no ambiguity is detected; 1 = dependencies exist without documentation or ambiguous references exist; 0 = evidence is unavailable
-- NOTE: Automated evidence uses dependency metadata and extended-property presence; documentation completeness requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Dependency evidence unavailable';
DECLARE @LinkedServerCount INT = 0;
DECLARE @CrossDatabaseReferenceCount INT = 0;
DECLARE @AmbiguousReferenceCount INT = 0;
DECLARE @DocumentedObjectCount INT = 0;
DECLARE @DependencyEvidenceCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @LinkedServerCount = COUNT(*)
    FROM sys.servers
    WHERE is_linked = 1;

    SELECT @CrossDatabaseReferenceCount = COUNT(*)
    FROM sys.sql_expression_dependencies
    WHERE referenced_database_name IS NOT NULL
      AND referenced_database_name <> DB_NAME();

    SELECT @AmbiguousReferenceCount = COUNT(*)
    FROM sys.sql_expression_dependencies
    WHERE is_ambiguous = 1;

    SELECT @DocumentedObjectCount = COUNT(*)
    FROM sys.extended_properties
    WHERE class = 1;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @DependencyEvidenceCount = @LinkedServerCount + @CrossDatabaseReferenceCount;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @DependencyEvidenceCount = 0 THEN 3
    WHEN @DocumentedObjectCount > 0 AND @AmbiguousReferenceCount = 0 THEN 3
    WHEN @DocumentedObjectCount > 0 OR @AmbiguousReferenceCount = 0 THEN 2
    WHEN @DependencyEvidenceCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'linked servers = ', @LinkedServerCount,
    N'; cross-database references = ', @CrossDatabaseReferenceCount,
    N'; ambiguous references = ', @AmbiguousReferenceCount,
    N'; documented objects (extended properties, class 1) = ', @DocumentedObjectCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more dependency sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
