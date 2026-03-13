USE master;
GO

SET NOCOUNT ON;
GO

CREATE PROCEDURE dbo.restoreheaderonly
    @backuplocation VARCHAR(MAX)
AS
BEGIN
    RESTORE FILELISTONLY
    FROM DISK = @backuplocation;
END
GO

