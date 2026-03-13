function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$ExpectJson
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed: $output"
    }

    $text = ($output | Out-String).Trim()
    if ($ExpectJson) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json -AsHashtable
    }

    return $text
}

function Test-AzureLogin {
    $null = Invoke-AzCli -Arguments @("account", "show", "--output", "json") -ExpectJson
}

function Get-AzureAccountInfo {
    return Invoke-AzCli -Arguments @("account", "show", "--output", "json") -ExpectJson
}

function Test-AzureResourceGroupExists {
    param([string]$Name)

    $result = Invoke-AzCli -Arguments @("group", "exists", "--name", $Name, "--output", "tsv")
    return $result -eq "true"
}

function Convert-AzureActionPatternToRegex {
    param([string]$Pattern)

    return "^$(([Regex]::Escape($Pattern)) -replace '\\\*', '.*')$"
}

function Test-AzureActionPatternMatch {
    param(
        [string]$Pattern,
        [string]$Action
    )

    return $Action -imatch (Convert-AzureActionPatternToRegex -Pattern $Pattern)
}

function Get-EffectivePermissionsForScope {
    param([string]$Scope)

    $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/permissions?api-version=2015-07-01"
    $result = Invoke-AzCli -Arguments @("rest", "--method", "get", "--url", $url, "--output", "json") -ExpectJson
    if ($null -eq $result -or $null -eq $result.value) {
        return @()
    }

    return @($result.value)
}

function Test-EffectiveAzureActionPermission {
    param(
        [object[]]$Permissions,
        [string]$Action
    )

    foreach ($entry in $Permissions) {
        $allowed = @($entry.actions)
        $blocked = @($entry.notActions)

        $isAllowed = $false
        foreach ($pattern in $allowed) {
            if (Test-AzureActionPatternMatch -Pattern $pattern -Action $Action) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            continue
        }

        $isBlocked = $false
        foreach ($pattern in $blocked) {
            if (Test-AzureActionPatternMatch -Pattern $pattern -Action $Action) {
                $isBlocked = $true
                break
            }
        }

        if (-not $isBlocked) {
            return $true
        }
    }

    return $false
}

function Test-AzureRequiredActions {
    param(
        [string]$ScopeLabel,
        [object[]]$Permissions,
        [object[]]$Checks
    )

    $results = @()
    foreach ($check in $Checks) {
        $missing = @()
        foreach ($action in $check.Actions) {
            if (-not (Test-EffectiveAzureActionPermission -Permissions $Permissions -Action $action)) {
                $missing += $action
            }
        }

        $results += [ordered]@{
            Name         = $check.Name
            Scope        = $ScopeLabel
            Passed       = ($missing.Count -eq 0)
            Missing      = $missing
            Description  = $check.Description
        }
    }

    return $results
}

function Get-TargetAzureSqlServerName {
    param([hashtable]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.AzureSqlServerFqdn)) {
        return $null
    }

    return ($Config.AzureSqlServerFqdn -replace '\.database\.windows\.net$', '')
}

function Test-TargetAzureSqlVisibility {
    param([hashtable]$Config)

    $serverName = Get-TargetAzureSqlServerName -Config $Config
    if ([string]::IsNullOrWhiteSpace($serverName)) {
        return
    }

    $null = Invoke-AzCli -Arguments @(
        "sql", "server", "show",
        "--resource-group", $Config.AzureResourceGroupName,
        "--name", $serverName,
        "--output", "json"
    ) -ExpectJson
}

function Export-PermissionReport {
    param(
        [string]$ArtifactsDirectory,
        [hashtable]$Report
    )

    $path = Join-Path $ArtifactsDirectory "permission-report.json"
    $Report | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Test-AzureRequiredPermissions {
    param([hashtable]$Config, [hashtable]$AccountInfo)

    $subscriptionScope = "/subscriptions/$($AccountInfo.id)"
    $resourceGroupScope = "$subscriptionScope/resourceGroups/$($Config.AzureResourceGroupName)"
    $resourceGroupExists = Test-AzureResourceGroupExists -Name $Config.AzureResourceGroupName

    $subscriptionPermissions = Get-EffectivePermissionsForScope -Scope $subscriptionScope
    $workloadScope = if ($resourceGroupExists) { $resourceGroupScope } else { $subscriptionScope }
    $workloadScopeLabel = if ($resourceGroupExists) { "resource group" } else { "subscription (resource group not created yet)" }
    $workloadPermissions = if ($resourceGroupExists) {
        Get-EffectivePermissionsForScope -Scope $resourceGroupScope
    }
    else {
        $subscriptionPermissions
    }

    $checks = @()
    if (-not $resourceGroupExists) {
        $checks += @{
            Name = "ResourceGroupCreate"
            Description = "Create the target resource group when it does not already exist."
            Actions = @(
                "Microsoft.Resources/subscriptions/resourceGroups/write"
            )
        }
    }

    $checks += @(
        @{
            Name = "Storage"
            Description = "Create or reuse the storage account and file share, and retrieve account keys for upload/mount."
            Actions = @(
                "Microsoft.Storage/storageAccounts/read",
                "Microsoft.Storage/storageAccounts/write",
                "Microsoft.Storage/storageAccounts/listkeys/action",
                "Microsoft.Storage/storageAccounts/fileServices/shares/read",
                "Microsoft.Storage/storageAccounts/fileServices/shares/write"
            )
        },
        @{
            Name = "ContainerRegistry"
            Description = "Create or reuse ACR, fetch credentials, and run an ACR build."
            Actions = @(
                "Microsoft.ContainerRegistry/registries/read",
                "Microsoft.ContainerRegistry/registries/write",
                "Microsoft.ContainerRegistry/registries/listCredentials/action",
                "Microsoft.ContainerRegistry/registries/listBuildSourceUploadUrl/action",
                "Microsoft.ContainerRegistry/registries/scheduleRun/action"
            )
        },
        @{
            Name = "ContainerInstance"
            Description = "Create, inspect, stream logs from, and delete the temporary ACI container group."
            Actions = @(
                "Microsoft.ContainerInstance/containerGroups/read",
                "Microsoft.ContainerInstance/containerGroups/write",
                "Microsoft.ContainerInstance/containerGroups/delete",
                "Microsoft.ContainerInstance/containerGroups/containers/logs/read"
            )
        },
        $(if (-not [string]::IsNullOrWhiteSpace($Config.AzureSqlServerFqdn)) {
            @{
                Name = "AzureSql"
                Description = "Read the target Azure SQL server resource and optionally delete the target database as fallback."
                Actions = @(
                    "Microsoft.Sql/servers/read"
                ) + $(if ($Config.AllowTargetDatabaseDeleteFallback) { @("Microsoft.Sql/servers/databases/delete") } else { @() })
            }
        })
    )

    $results = @()
    if (-not $resourceGroupExists) {
        $results += Test-AzureRequiredActions -ScopeLabel "subscription" -Permissions $subscriptionPermissions -Checks @($checks[0])
        $results += Test-AzureRequiredActions -ScopeLabel $workloadScopeLabel -Permissions $workloadPermissions -Checks $checks[1..($checks.Count - 1)]
    }
    else {
        $results += Test-AzureRequiredActions -ScopeLabel $workloadScopeLabel -Permissions $workloadPermissions -Checks $checks
    }

    Write-Step "Running Azure permission preflight"
    foreach ($result in $results) {
        if ($result.Passed) {
            Write-Host "[PASS] $($result.Name): $($result.Description)"
        }
        else {
            Write-Host "[FAIL] $($result.Name): missing $($result.Missing -join ', ')"
        }
    }

    Test-TargetAzureSqlVisibility -Config $Config

    $report = [ordered]@{
        CheckedAt           = (Get-Date).ToString("o")
        SubscriptionId      = $AccountInfo.id
        ResourceGroupName   = $Config.AzureResourceGroupName
        ResourceGroupExists = $resourceGroupExists
        WorkloadScope       = $workloadScope
        Results             = $results
        TargetAzureSqlServer = Get-TargetAzureSqlServerName -Config $Config
    }
    $reportPath = Export-PermissionReport -ArtifactsDirectory $Config.ArtifactsDirectory -Report $report
    Write-Host "Permission report: $reportPath"

    $failed = @($results | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0) {
        $details = $failed | ForEach-Object { "$($_.Name): $($_.Missing -join ', ')" }
        throw "Azure permission preflight failed. Missing required actions: $($details -join '; ')"
    }
}

function Ensure-AzureResourceGroup {
    param([hashtable]$Config, [hashtable]$State)

    $existing = & az group show -n $Config.AzureResourceGroupName --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Update-StateValue -State $State -Key "ResourceGroupCreated" -Value $false
        return
    }

    Write-Step "Creating resource group $($Config.AzureResourceGroupName)"
    $null = Invoke-AzCli -Arguments @("group", "create", "--name", $Config.AzureResourceGroupName, "--location", $Config.AzureLocation, "--output", "json") -ExpectJson
    Update-StateValue -State $State -Key "ResourceGroupCreated" -Value $true
}

function Ensure-StorageAccount {
    param([hashtable]$Config, [hashtable]$State)

    $existing = & az storage account show -g $Config.AzureResourceGroupName -n $Config.StorageAccountName --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Update-StateValue -State $State -Key "StorageAccountCreated" -Value $false
        Wait-StorageAccountReady -Config $Config
        return
    }

    Write-Step "Creating storage account $($Config.StorageAccountName)"
    $null = Invoke-AzCli -Arguments @(
        "storage", "account", "create",
        "--resource-group", $Config.AzureResourceGroupName,
        "--name", $Config.StorageAccountName,
        "--location", $Config.AzureLocation,
        "--sku", "Standard_LRS",
        "--kind", "StorageV2",
        "--output", "json"
    ) -ExpectJson
    Update-StateValue -State $State -Key "StorageAccountCreated" -Value $true
    Wait-StorageAccountReady -Config $Config
}

function Wait-StorageAccountReady {
    param(
        [hashtable]$Config,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $account = & az storage account show -g $Config.AzureResourceGroupName -n $Config.StorageAccountName --query "{state:provisioningState,kind:kind}" --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($account)) {
            $json = $account | ConvertFrom-Json -AsHashtable
            if ($json.state -eq "Succeeded") {
                return
            }
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Storage account $($Config.StorageAccountName) did not reach Succeeded state in time."
}

function Get-StorageAccountKey {
    param([hashtable]$Config)

    $keys = Invoke-AzCli -Arguments @(
        "storage", "account", "keys", "list",
        "-g", $Config.AzureResourceGroupName,
        "-n", $Config.StorageAccountName,
        "--output", "json"
    ) -ExpectJson

    return $keys[0].value
}

function Ensure-StorageShare {
    param([hashtable]$Config, [hashtable]$State)

    Wait-StorageAccountReady -Config $Config

    $existing = & az storage share-rm show --resource-group $Config.AzureResourceGroupName --storage-account $Config.StorageAccountName --name $Config.StorageShareName --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Update-StateValue -State $State -Key "StorageShareCreated" -Value $false
        return
    }

    Write-Step "Creating file share $($Config.StorageShareName)"
    $deadline = (Get-Date).AddMinutes(5)
    do {
        try {
            $null = Invoke-AzCli -Arguments @(
                "storage", "share-rm", "create",
                "--resource-group", $Config.AzureResourceGroupName,
                "--storage-account", $Config.StorageAccountName,
                "--name", $Config.StorageShareName,
                "--quota", "100",
                "--enabled-protocols", "SMB",
                "--output", "json"
            ) -ExpectJson
            Update-StateValue -State $State -Key "StorageShareCreated" -Value $true
            return
        }
        catch {
            if ($_.Exception.Message -notmatch "ResourceNotFound") {
                throw
            }
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $deadline)

    throw "Storage share $($Config.StorageShareName) could not be created before timeout."
}

function Ensure-ContainerRegistry {
    param([hashtable]$Config, [hashtable]$State)

    $existing = & az acr show -g $Config.AzureResourceGroupName -n $Config.ContainerRegistryName --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Update-StateValue -State $State -Key "ContainerRegistryCreated" -Value $false
        return
    }

    Write-Step "Creating container registry $($Config.ContainerRegistryName)"
    $null = Invoke-AzCli -Arguments @(
        "acr", "create",
        "--resource-group", $Config.AzureResourceGroupName,
        "--name", $Config.ContainerRegistryName,
        "--sku", "Basic",
        "--admin-enabled", "true",
        "--location", $Config.AzureLocation,
        "--output", "json"
    ) -ExpectJson
    Update-StateValue -State $State -Key "ContainerRegistryCreated" -Value $true
}

function Get-ContainerRegistryCredentials {
    param([hashtable]$Config)

    return Invoke-AzCli -Arguments @(
        "acr", "credential", "show",
        "--name", $Config.ContainerRegistryName,
        "--output", "json"
    ) -ExpectJson
}

function Invoke-AcrBuildForRestoreImage {
    param([hashtable]$Config)

    Write-Step "Building restore image in ACR"
    $context = Resolve-RelativePath -BasePath $PSScriptRoot -Path "../../docker"
    $null = Invoke-AzCli -Arguments @(
        "acr", "build",
        "--registry", $Config.ContainerRegistryName,
        "--image", "sql/bak-bacpac:latest",
        $context,
        "--output", "none"
    )
}

function Upload-BackupToFileShare {
    param([hashtable]$Config)

    Write-Step "Uploading backup to Azure Files"
    $storageKey = Get-StorageAccountKey -Config $Config
    $null = Invoke-AzCli -Arguments @(
        "storage", "file", "upload",
        "--account-name", $Config.StorageAccountName,
        "--account-key", $storageKey,
        "--share-name", $Config.StorageShareName,
        "--source", $Config.BakPath,
        "--path", ([System.IO.Path]::GetFileName($Config.BakPath)),
        "--output", "none"
    )
}

function New-RestoreContainerInstance {
    param([hashtable]$Config, [hashtable]$State)

    $storageKey = Get-StorageAccountKey -Config $Config
    $registryCreds = Get-ContainerRegistryCredentials -Config $Config

    Write-Step "Creating Azure Container Instance $($Config.ContainerGroupName)"
    $result = Invoke-AzCli -Arguments @(
        "container", "create",
        "--resource-group", $Config.AzureResourceGroupName,
        "--name", $Config.ContainerGroupName,
        "--image", "$($Config.ContainerRegistryName).azurecr.io/sql/bak-bacpac:latest",
        "--registry-login-server", "$($Config.ContainerRegistryName).azurecr.io",
        "--registry-username", $registryCreds.username,
        "--registry-password", $registryCreds.passwords[0].value,
        "--os-type", "Linux",
        "--cpu", "2",
        "--memory", "4",
        "--restart-policy", "Never",
        "--ip-address", "Public",
        "--ports", "1433",
        "--azure-file-volume-share-name", $Config.StorageShareName,
        "--azure-file-volume-account-name", $Config.StorageAccountName,
        "--azure-file-volume-account-key", $storageKey,
        "--azure-file-volume-mount-path", "/mnt/external",
        "--environment-variables", "ACCEPT_EULA=Y", "MSSQL_PID=Developer", "SKIP_INTERNAL_EXPORT=1",
        "--secure-environment-variables", "SA_PASSWORD=$($Config.ContainerSaPassword)",
        "--output", "json"
    ) -ExpectJson

    Update-StateValue -State $State -Key "ContainerPublicIp" -Value $result.ipAddress.ip
}

function Wait-ContainerInstanceReady {
    param([hashtable]$Config, [int]$TimeoutSeconds = 600)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = & az container show --resource-group $Config.AzureResourceGroupName --name $Config.ContainerGroupName --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($result)) {
            $json = $result | ConvertFrom-Json -AsHashtable
            if ($json.provisioningState -eq "Succeeded" -and $json.containers[0].instanceView.currentState.state -eq "Running") {
                return $json
            }
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Container instance $($Config.ContainerGroupName) did not reach Running state in time."
}

function Get-ContainerLogs {
    param([hashtable]$Config)

    return & az container logs --resource-group $Config.AzureResourceGroupName --name $Config.ContainerGroupName 2>&1 | Out-String
}

function Remove-TemporaryResources {
    param([hashtable]$Config, [hashtable]$State)

    if ($Config.KeepTemporaryAzureResources) {
        Write-Step "Keeping temporary Azure resources"
        return
    }

    if ($Config.ContainerGroupName) {
        & az container delete --resource-group $Config.AzureResourceGroupName --name $Config.ContainerGroupName --yes 2>$null | Out-Null
    }

    if ($State.ContainerRegistryCreated) {
        & az acr delete --resource-group $Config.AzureResourceGroupName --name $Config.ContainerRegistryName --yes 2>$null | Out-Null
    }

    if ($State.StorageShareCreated) {
        & az storage share-rm delete --resource-group $Config.AzureResourceGroupName --storage-account $Config.StorageAccountName --name $Config.StorageShareName --yes 2>$null | Out-Null
    }

    if ($State.StorageAccountCreated) {
        & az storage account delete --resource-group $Config.AzureResourceGroupName --name $Config.StorageAccountName --yes 2>$null | Out-Null
    }

    if ($State.ResourceGroupCreated) {
        & az group delete --name $Config.AzureResourceGroupName --yes --no-wait 2>$null | Out-Null
    }

    foreach ($key in @(
        "TempSqlHost",
        "ContainerPublicIp",
        "ContainerSaPassword",
        "ContainerSaPasswordSet",
        "StorageAccountCreated",
        "StorageShareCreated",
        "ContainerRegistryCreated",
        "ResourceGroupCreated"
    )) {
        Remove-StateValue -State $State -Key $key
    }

    Save-RunState -State $State -ArtifactsDirectory $Config.ArtifactsDirectory | Out-Null
}
