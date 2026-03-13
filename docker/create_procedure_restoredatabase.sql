CREATE PROCEDURE dbo.restoredatabase
    @backuplocation VARCHAR(MAX),
    @dbname VARCHAR(255)
AS
BEGIN
    DECLARE @restorelocation VARCHAR(255), @sql VARCHAR(MAX), @escapedbackuplocation VARCHAR(MAX), @quoteddbname SYSNAME;

    SET @restorelocation = '/var/opt/mssql/data/';
    SET @escapedbackuplocation = REPLACE(@backuplocation, '''', '''''');
    SET @quoteddbname = QUOTENAME(@dbname);

    CREATE TABLE #tblBackupFiles
    (
        LogicalName VARCHAR(255),
        PhysicalName VARCHAR(255),
        [Type] CHAR(1),
        FileGroupName VARCHAR(50),
        Size BIGINT,
        MaxSize BIGINT,
        FileId INT,
        CreateLSN NUMERIC(30,2),
        DropLSN NUMERIC(30,2),
        UniqueId UNIQUEIDENTIFIER,
        ReadOnlyLSN NUMERIC(30,2),
        ReadWriteLSN NUMERIC(30,2),
        BackupSizeInBytes BIGINT,
        SourceBlockSize INT,
        FileGroupId INT,
        LogGroupGUID UNIQUEIDENTIFIER,
        DifferentialBaseLSN NUMERIC(30,2),
        DifferentialBaseGUID UNIQUEIDENTIFIER,
        IsReadOnly INT,
        IsPresent INT,
        TDEThumbprint VARCHAR(10),
        SnapshotUrl VARCHAR(255)
    );

    INSERT INTO #tblBackupFiles
    EXEC dbo.restoreheaderonly @backuplocation;

    SET @sql = 'RESTORE DATABASE ' + @quoteddbname + ' FROM DISK = N''' + @escapedbackuplocation + ''' WITH ';

    SELECT @sql = @sql + CHAR(13)
        + ' MOVE N''' + REPLACE(LogicalName, '''', '''''') + ''' TO N'''
        + REPLACE(@restorelocation + LogicalName, '''', '''''')
        + CASE WHEN [Type] = 'L' THEN '.ldf' ELSE '.mdf' END + ''','
    FROM #tblBackupFiles
    WHERE IsPresent = 1;

    SET @sql = SUBSTRING(@sql, 1, LEN(@sql) - 1);

    PRINT @sql;
    EXEC (@sql);

    DROP TABLE #tblBackupFiles;
END
