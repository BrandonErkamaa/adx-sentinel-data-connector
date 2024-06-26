param($Timer)

$currentUTCtime = (Get-Date).ToUniversalTime()

if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late! $($Timer.ScheduledStatus.Last)"
}

# Install necessary modules
Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber
Install-Module -Name Az.Kusto -Scope CurrentUser -Force -AllowClobber

# Environment variables
$ADX_CLUSTER = $env:ADX_CLUSTER
$ADX_DATABASE = $env:ADX_DATABASE
$TABLE_NAME = $env:TABLE_NAME
$SENTINEL_WORKSPACE_ID = $env:SENTINEL_WORKSPACE_ID
$logAnalyticsUri = "https://" + $SENTINEL_WORKSPACE_ID + ".ods.opinsights.azure.com"
$SENTINEL_SHARED_KEY = $env:SENTINEL_WORKSPACE_KEY
$STORAGE_CONNECTION_STRING = $env:AzureWebJobsStorage
$STATE_TABLE_NAME = "adxStateTable"
$STATE_PARTITION_KEY = "adxState"
$STATE_ROW_KEY = "lastProcessedRow"

$tenantId = "8f445392-4de8-4998-80f6-1f324068d229"
$SubscriptionId = "df87a0ba-c88a-4273-83f9-23338d08f3fc"
$ClientID = "5614d2cd-2239-43b3-8dc5-209512107993"

# Function to get ADX token using Managed Identity
function GetAdxToken {
    Write-Host "Logging in using User Managed Identity"
    $null = Connect-AzAccount -Identity -AccountId $ClientID

    Write-Host "Getting token"
    $resource = "https://smartaccessexplorer.centralus.kusto.windows.net"
    $token = (Get-AzAccessToken -ResourceUrl $resource).Token

    return [string]$token
}

# Function to query ADX using the retrieved token
function QueryAdx {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token
    )
    Write-Host "Querying ADX"

    # Check the token's validity
    if (-not $token) {
        throw "Token is null or empty. Aborting query."
    }

    $headers = @{
        "Authorization" = "Bearer $token"
    }

    $uri = "https://$ADX_CLUSTER.centralus.kusto.windows.net/v2/rest/query"
    
    # Query to take 10 rows from the table
    $query = "['$TABLE_NAME'] | take 10"

    $body = @{
        "db"  = $ADX_DATABASE
        "csl" = $query
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json" -Body $body
        return $response
    }
    catch {
        Write-Error "Error querying ADX: $_"
        throw
    }
}

# Function to build the signature for the request
Function Build-Signature {
    param (
        [string]$customerId,
        [string]$sharedKey,
        [string]$date,
        [int]$contentLength,
        [string]$method,
        [string]$contentType,
        [string]$resource
    )
    
    Write-Host "Building signature"

    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    
    # Dispose SHA256 from heap before return.
    $sha256.Dispose()

    return $authorization 
}

# Function to create and invoke an API POST request to the Log Analytics Data Connector API
Function Post-LogAnalyticsData {
    param (
        [string]$customerId,
        [string]$sharedKey,
        [string]$body,
        [string]$logType
    )
    write-host "Posting logs to Azure Sentinel"

    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    
    $uri = $logAnalyticsUri + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = "TimeGenerated";
    }
    try {
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    }
    catch {
        Write-Error "Error during sending logs to Azure Sentinel: $_"
        throw $_  # Re-throwing to capture in the outer try-catch
    }
    if ($response.StatusCode -eq 200) {
        Write-Host "Logs have been successfully sent to Azure Sentinel."
    }
    else {
        Write-Host "Error during sending logs to Azure Sentinel. Response code : $response.StatusCode"
    }

    return $response.StatusCode
}

# Function to format ADX results for Sentinel
Function Format-AdxResultsForSentinel {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$adxResults
    )

    Write-Host "Formatting ADX results for Sentinel"

    # Extract DataTables
    $dataTables = $adxResults | Where-Object { $_.FrameType -eq 'DataTable' }

    # Find the PrimaryResult table
    $primaryResultTable = $dataTables | Where-Object { $_.TableKind -eq 'PrimaryResult' }

    if (-not $primaryResultTable) {
        throw "No 'PrimaryResult' table found in ADX results."
    }

    # Extract columns and rows
    $columns = $primaryResultTable.Columns | ForEach-Object { $_.ColumnName }
    Write-Host "Columns: $($columns -join ',')"
    $rows = $primaryResultTable.Rows
    Write-Host "Rows: $($rows.Count)"

    $formattedResults = @()
    foreach ($row in $rows) {
        $formattedRow = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $formattedRow[$columns[$i]] = $row[$i]
        }
        $formattedResults += [PSCustomObject]$formattedRow
    }
    Write-Host "Formatted Results: $($formattedResults -join ',')"

    return $formattedResults
}

# Rest of the code remains unchanged

# Timer-triggered function execution
try {
    # Get new data from ADX
    $token = GetAdxToken
    $results = QueryAdx -token $token

    $results | Format-List -Force
    Write-Output "Query Results:"
    Write-Output $results

    # Format the results for Sentinel
    $formattedResults = Format-AdxResultsForSentinel -adxResults $results
    Write-Host "Formatted Results for Sentinel:"
    Write-Output $formattedResults

    # Convert formatted results to JSON
    $jsonBody = $formattedResults | ConvertTo-Json -Depth 10 -Compress
    Write-Host "JSON Body: $jsonBody"
    
    # Send the results to Sentinel
    $logName = "TestTable2"
    Write-Host "Sentinel_Workspace_ID: $SENTINEL_WORKSPACE_ID"
    Write-Host "Sentinel_Shared_Key: $SENTINEL_SHARED_KEY"

    $statusCode = Post-LogAnalyticsData -customerId $SENTINEL_WORKSPACE_ID -sharedKey $SENTINEL_SHARED_KEY -body $jsonBody -logType $logName
    Write-Host “Post-LogAnalyticsData returned status code: $statusCode”
}
catch {
    Write-Error “Error during function execution: $_”
}