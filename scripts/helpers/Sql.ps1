function Open-SqlConnection {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password,
        [bool]$Encrypt = $false,
        [bool]$TrustServerCertificate = $true
    )

    $connectionString = "Server=$Server;Database=$Database;User ID=$User;Password=$Password;Encrypt=$Encrypt;TrustServerCertificate=$TrustServerCertificate"
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    return $connection
}

function Invoke-SqlQuery {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password,
        [string]$Sql,
        [hashtable]$Parameters
    )

    $connection = Open-SqlConnection -Server $Server -Database $Database -User $User -Password $Password
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql

        if ($Parameters) {
            foreach ($key in $Parameters.Keys) {
                $param = $command.Parameters.Add("@$key", [System.Data.SqlDbType]::NVarChar, 4000)
                $param.Value = [string]$Parameters[$key]
            }
        }

        $reader = $command.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)
        return $table
    }
    finally {
        $connection.Close()
    }
}

function Invoke-SqlNonQuery {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password,
        [string]$Sql
    )

    $connection = Open-SqlConnection -Server $Server -Database $Database -User $User -Password $Password
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Close()
    }
}

function Invoke-SqlScalar {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string]$Password,
        [string]$Sql,
        [hashtable]$Parameters,
        [bool]$Encrypt = $false,
        [bool]$TrustServerCertificate = $true
    )

    $connection = Open-SqlConnection -Server $Server -Database $Database -User $User -Password $Password -Encrypt $Encrypt -TrustServerCertificate $TrustServerCertificate
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql

        if ($Parameters) {
            foreach ($key in $Parameters.Keys) {
                $param = $command.Parameters.Add("@$key", [System.Data.SqlDbType]::NVarChar, 4000)
                $param.Value = [string]$Parameters[$key]
            }
        }

        return $command.ExecuteScalar()
    }
    finally {
        $connection.Close()
    }
}

function Wait-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($HostName, $Port, $null, $null)
            $success = $iar.AsyncWaitHandle.WaitOne(2000, $false)
            if ($success -and $client.Connected) {
                $client.EndConnect($iar)
                $client.Close()
                return
            }
            $client.Close()
        }
        catch {
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "TCP port ${HostName}:$Port did not become reachable in time."
}

function Wait-TempSqlServerReady {
    param(
        [string]$Server,
        [string]$User,
        [string]$Password,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $value = Invoke-SqlScalar -Server $Server -Database "master" -User $User -Password $Password -Sql "SELECT TOP (1) 1 FROM sys.databases"
            if ($null -ne $value) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Temporary SQL Server at $Server did not become ready in time."
}

function Wait-RestoredDatabaseReady {
    param(
        [string]$Server,
        [string]$User,
        [string]$Password,
        [string]$DatabaseName,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $state = Invoke-SqlScalar -Server $Server -Database "master" -User $User -Password $Password -Sql "SELECT state_desc FROM sys.databases WHERE name = @db" -Parameters @{ db = $DatabaseName }
            if ([string]$state -eq "ONLINE") {
                return
            }
        }
        catch {
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Restored database $DatabaseName did not reach ONLINE state in time."
}

function Export-BacpacFromTempSql {
    param([hashtable]$Config, [string]$TempSqlServer)

    $databaseName = if (-not [string]::IsNullOrWhiteSpace($Config.RestoredDatabaseName)) {
        $Config.RestoredDatabaseName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Config.BakPath)) {
        [System.IO.Path]::GetFileNameWithoutExtension($Config.BakPath)
    }
    else {
        throw "RestoredDatabaseName or BakPath is required for bacpac export."
    }

    $bacpacBaseName = if (-not [string]::IsNullOrWhiteSpace($Config.BacpacPath)) {
        $Config.BacpacPath
    }
    else {
        Join-Path $Config.ArtifactsDirectory ($databaseName + ".bacpac")
    }

    $bacpacPath = $bacpacBaseName
    if (Test-Path -LiteralPath $bacpacPath) {
        Remove-Item -LiteralPath $bacpacPath -Force
    }

    Write-Step "Exporting bacpac with host SqlPackage"
    $exportOutput = & $Config.SqlPackagePath `
        /Action:Export `
        "/SourceServerName:$TempSqlServer" `
        "/SourceDatabaseName:$databaseName" `
        /SourceUser:sa `
        "/SourcePassword:$($Config.ContainerSaPassword)" `
        /SourceEncryptConnection:Optional `
        /SourceTrustServerCertificate:True `
        "/TargetFile:$bacpacPath" `
        /p:CommandTimeout=1200 `
        /p:LongRunningCommandTimeout=0 `
        /p:VerifyExtraction=False
    $exportOutput | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "SqlPackage export failed."
    }

    return $bacpacPath
}

function Import-BacpacToAzureSql {
    param([hashtable]$Config, [string]$BacpacPath)

    Write-Step "Importing bacpac into Azure SQL"
    $importOutput = & $Config.SqlPackagePath `
        /Action:Import `
        "/SourceFile:$BacpacPath" `
        "/TargetServerName:$($Config.AzureSqlServerFqdn)" `
        "/TargetDatabaseName:$($Config.AzureSqlDatabaseName)" `
        "/TargetUser:$($Config.SqlAdminUser)" `
        "/TargetPassword:$($Config.SqlAdminPassword)" `
        /TargetEncryptConnection:True `
        /TargetTrustServerCertificate:False `
        /p:DatabaseEdition=Standard `
        /p:DatabaseServiceObjective=S1 `
        /p:DatabaseMaximumSize=250 `
        /p:CommandTimeout=1200 `
        /p:LongRunningCommandTimeout=0
    $importOutput | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "SqlPackage import failed."
    }
}

function Remove-AzureSqlDatabase {
    param([hashtable]$Config)

    Write-Step "Deleting target Azure SQL database $($Config.AzureSqlDatabaseName)"
    $null = Invoke-AzCli -Arguments @(
        "sql", "db", "delete",
        "--yes",
        "--resource-group", $Config.AzureResourceGroupName,
        "--server", ($Config.AzureSqlServerFqdn -replace '\.database\.windows\.net$', ''),
        "--name", $Config.AzureSqlDatabaseName
    )
}

function Get-AzureSqlTableCount {
    param([hashtable]$Config)

    $connection = Open-SqlConnection -Server "$($Config.AzureSqlServerFqdn),1433" -Database $Config.AzureSqlDatabaseName -User $Config.SqlAdminUser -Password $Config.SqlAdminPassword -Encrypt $true -TrustServerCertificate $false
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT COUNT(*) FROM sys.tables"
        $reader = $command.ExecuteReader()
        try {
            if (-not $reader.Read()) {
                throw "Table count query returned no rows."
            }

            return $reader.GetInt32(0)
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $connection.Close()
    }
}
