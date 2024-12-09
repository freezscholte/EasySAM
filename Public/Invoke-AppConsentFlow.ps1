function Invoke-AppConsentFlow {
    <#
    .SYNOPSIS
    Initiates the app consent flow for Microsoft Partner Center API access across customer tenants.

    .DESCRIPTION
    This function automates the process of obtaining admin consent for Partner Center API permissions 
    across specified customer tenants or all customer tenants. It handles the OAuth2 authorization flow,
    including opening the consent page in a browser and capturing the authorization response.

    .PARAMETER redirectUri
    The redirect URI configured in the app registration. Defaults to 'http://localhost:8400'.

    .PARAMETER scope
    The permission scope requested. Defaults to 'https://api.partnercenter.microsoft.com/.default'.

    .PARAMETER Customers
    Array of customer objects containing customerId and displayName properties.

    .PARAMETER AllCustomers
    Switch to process consent flow for all customers. When specified, the function will retrieve
    all customer tenants from Partner Center automatically.

    .PARAMETER UpdateSamPermission
    Switch to force update existing SAM application permissions in customer tenants.

    .PARAMETER SAMConfigObject
    Optional PSCustomObject containing SAM configuration. If not provided, will use existing or imported config.

    .PARAMETER existingSAM
    Switch to import SAM configuration from file instead of using existing config.

    .EXAMPLE
    # Process specific customers with existing SAM config
    $customers = @(
        [PSCustomObject]@{ customerId = "tenant-id-1"; displayName = "Customer1" }
    )
    Invoke-AppConsentFlow -Customers $customers

    .EXAMPLE
    # Process all customers with provided SAM config
    $samConfig = Get-MySAMConfig
    Invoke-AppConsentFlow -AllCustomers -SAMConfigObject $samConfig

    .EXAMPLE
    # Process multiple customers with existing SAM config
    $customers = @(
        [PSCustomObject]@{ customerId = "tenant-id-1"; displayName = "Customer1" },
        [PSCustomObject]@{ customerId = "tenant-id-2"; displayName = "Customer2" }
    )
    Invoke-AppConsentFlow -Customers $customers -SAMConfigObject $samConfig

    .EXAMPLE
    # Process all customers without providing SAM config
    Invoke-AppConsentFlow -AllCustomers

    .EXAMPLE
    # Update SAM permissions for specific customers
    $customers = @(
        [PSCustomObject]@{ customerId = "tenant-id-3"; displayName = "Customer3" }
    )
    Invoke-AppConsentFlow -Customers $customers -UpdateSamPermission -Verbose

    .EXAMPLE
    # Import SAM configuration from file and process specific customers
    Invoke-AppConsentFlow -Customers $customers -existingSAM -Verbose

    .NOTES
    Requires appropriate Partner Center API permissions and admin consent capability.
    #>

    [CmdletBinding(DefaultParameterSetName = 'Specific')]
    param (
        [Parameter(ParameterSetName = 'Specific')]
        [Parameter(ParameterSetName = 'All')]
        [string]$redirectUri = 'http://localhost:8400',

        [Parameter(ParameterSetName = 'Specific')]
        [Parameter(ParameterSetName = 'All')]
        [string]$scope = 'https://api.partnercenter.microsoft.com/.default',

        [Parameter(Mandatory, ParameterSetName = 'Specific')]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject[]]$Customers,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$AllCustomers,

        [Parameter(ParameterSetName = 'Specific')]
        [Parameter(ParameterSetName = 'All')] 
        [switch]$UpdateSamPermission,

        [Parameter(ParameterSetName = 'Specific')]
        [Parameter(ParameterSetName = 'All')]
        [PSCustomObject]$SAMConfigObject,

        [Parameter(ParameterSetName = 'Specific')]
        [Parameter(ParameterSetName = 'All')] 
        [switch]$existingSAM
    )

    $samConfig = $null
    # Initialize SAM configuration as local variable
    $samConfig = if ($SAMConfigObject) {
        Write-Verbose "Using provided SAM configuration object"
        $SAMConfigObject
    }
    elseif ($existingSAM) {
        Write-Verbose "Importing SAM configuration from file"
        $config = Import-SAMConfig
        if (-not $config) {
            throw "SAM configuration import failed. Please check the configuration."
        }
        $config
    }
    elseif ($global:SAMConfig) {
        Write-Verbose "Using existing SAM configuration"
        $global:SAMConfig
    }
    else {
        throw "SAM configuration not found. Please run Invoke-NewSAM first or provide a configuration."
    }

    # Ensure we have a single object, not an array
    if ($samConfig -is [Array]) {
        Write-Verbose "Converting array to single object"
        $samConfig = $samConfig[0]
    }

    Write-Verbose "SAM Configuration Type: $($samConfig.GetType().FullName)"
    Write-Verbose "SAM Configuration:"
    Write-Verbose ($samConfig | ConvertTo-Json)

    try {
        #Generate MSP token using SAM
        $MSPGraphParams = @{
            ApplicationId     = $samConfig.ApplicationId
            ApplicationSecret = $samConfig.ApplicationSecret
            RefreshToken      = $samConfig.RefreshToken
            TenantID          = $samConfig.TenantId
        }
        Write-Verbose "Getting MSP token..."
        $MSPtoken = Connect-GraphApiSAM @MSPGraphParams
        if (-not $MSPtoken) {
            throw "Failed to generate MSP token"
        }
    }
    catch {
        Write-Error "Error generating MSP token: $_"
        throw
    }

    try {
        # Get the MSP Access Token
        $AccessTokenParams = @{
            ApplicationId     = $samConfig.ApplicationId
            ApplicationSecret = $samConfig.ApplicationSecret
            TenantID          = $samConfig.TenantId
        }
        Write-Verbose "Getting MSP access token..."
        $MSPAccessToken = Get-PartnerSAMTokens @AccessTokenParams
        if (-not $MSPAccessToken) {
            throw "Failed to generate MSP access token"
        }
    }
    catch {
        Write-Error "Error generating MSP access token: $_"
        throw
    }

    if (-not $MSPtoken -or -not $MSPAccessToken) {
        throw "Failed to generate required tokens"
    }

    try {
        if ($AllCustomers) {
            Write-Output "Retrieving all customers from Partner Center..."
            $Customers = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/contracts?`$top=999" -Method GET -Headers $MSPtoken).value
            Write-Output "Found $($Customers.Count) customers"
        }
    }
    catch {
        Write-Error "Failed to retrieve customers: $_"
        return
    }

    # Get application details and permissions configuration outside the loop
    $appDetails = $null
    $permissionsConfig = $null

    try {
        # Get application details from MSP Tenant
        Write-Verbose "Retrieving application details for AppId: $($samConfig.ApplicationId)"
        $appDetailsUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($samConfig.ApplicationId)'"
        $appDetails = Invoke-RestMethod -Uri $appDetailsUri -Headers $MSPtoken -Method Get -Verbose
            
        if (-not $appDetails.value) {
            throw "Application with ID $($samConfig.ApplicationId) not found"
        }
        $app = $appDetails.value[0]

        # Get permissions configuration from JSON
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Config\samPermissions.json"
        if (-not (Test-Path -Path $configPath)) {
            throw "Permissions configuration file not found at: $configPath"
        }
        $permissionsConfig = Get-Content -Path $configPath -Raw | ConvertFrom-Json -Depth 20 
    }
    catch {
        Write-Error "Critical error in setup: $_"
        return
    }

    $applicationGrants = $permissionsConfig.applicationGrants
    $appRoles = $permissionsConfig.appRoles

    # Initialize a list to store failed customers
    $failedCustomers = @()

    # Process each customer tenant
    $Customers | ForEach-Object {
        $currentTenant = $_
        Write-Output "Processing tenant: $($currentTenant.displayName)"
            
        try {
            $customerToken = $null
            $existingApp = $null

            # Try to connect to customer tenant
            try {
                $CustomerGraphParams = @{
                    ApplicationId     = $samConfig.ApplicationId
                    ApplicationSecret = $samConfig.ApplicationSecret 
                    RefreshToken      = $samConfig.RefreshToken
                    TenantID          = $currentTenant.customerId
                }
                $customerToken = Connect-GraphApiSAM @CustomerGraphParams

                if ($customerToken) {
                    # Check if SAM app exists in tenant
                    $customerHeaders = @{
                        "Authorization" = $customerToken.Authorization
                        "Content-Type"  = "application/json"
                    }

                    $filterAppId = [System.Web.HttpUtility]::UrlEncode("appId eq '$($samConfig.ApplicationId)'")
                    $appUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filterAppId"
                    
                    $existingApp = (Invoke-RestMethod -Uri $appUri -Headers $customerHeaders -Method Get).value
                }
            }
            catch {
                Write-Output "Info: Unable to check existing app in tenant $($currentTenant.displayName). This is expected if app consent is not yet granted."
                Write-Verbose "Error details: $_"
                # Continue with the consent flow
            }

            # Process existing app if found
            if ($existingApp) {
                Write-Output "SAM application found in tenant: $($currentTenant.displayName)"
                    
                if ($UpdateSamPermission) {
                    Write-Output "Removing existing SAM application..."
                    $spId = $existingApp.id
                    $deleteUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$spId"
                        
                    try {
                        # Delete the existing app
                        Invoke-RestMethod -Uri $deleteUri -Headers $customerHeaders -Method Delete
                        Write-Output "Existing SAM application removed, waiting for deletion to propagate..."
                            
                        # Wait and verify deletion with exponential backoff
                        $maxAttempts = 6
                        $attempt = 0
                        $waitTime = 10
                            
                        do {
                            $attempt++
                            Write-Output "Verification attempt $attempt of $maxAttempts (waiting $waitTime seconds)..."
                            Start-Sleep -Seconds $waitTime
                                
                            # Check if app still exists
                            $verifyUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filterAppId"
                            try {
                                $verifyApp = (Invoke-RestMethod -Uri $verifyUri -Headers $customerHeaders -Method Get).value
                                if (-not $verifyApp) {
                                    Write-Output "Application successfully removed"
                                    break
                                }
                                Write-Output "Application still exists, waiting longer..."
                                $waitTime *= 2  # Exponential backoff
                            }
                            catch {
                                # If we get a 404 or similar, the app is gone
                                if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                                    Write-Output "Application successfully removed"
                                    break
                                }
                                Write-Verbose "Verification error: $_"
                            }
                        } while ($attempt -lt $maxAttempts)

                        if ($attempt -ge $maxAttempts) {
                            throw "Timeout waiting for application deletion to complete"
                        }

                        # Additional safety delay
                        Write-Output "Waiting additional 20 seconds for changes to propagate..."
                        Start-Sleep -Seconds 20
                    }
                    catch {
                        Write-Error "Failed to remove existing SAM application: $_"
                        continue
                    }
                }
                else {
                    Write-Output "Skipping tenant as SAM application already exists. Use -UpdateSamPermission to force update."
                    return
                }
            }
            else {
                Write-Output "No existing SAM application found in tenant. Proceeding with creation..."
            }

            # Proceed with consent process
            try {
                $consentBody = @{
                    applicationGrants = $applicationGrants
                    appRoles          = $appRoles
                    applicationId     = $app.appId
                    displayName       = $app.displayName
                }

                $AppConsentHeaders = @{
                    Authorization  = "Bearer $($MSPAccessToken.Access_Token)"
                    'Content-Type' = 'application/json'
                }

                Write-Verbose "Consent body:"
                Write-Verbose ($consentBody | ConvertTo-Json -Depth 10)

                $uri = "https://api.partnercenter.microsoft.com/v1/customers/$($currentTenant.customerId)/applicationconsents"
                    
                $response = Invoke-RestMethod -Uri $uri -Headers $AppConsentHeaders -Method Post -Body ($consentBody | ConvertTo-Json -Depth 20)
                Write-Output "Successfully processed tenant: $($currentTenant.displayName)"
                $response
            }
            catch {
                throw  # Rethrow to be caught by outer catch block
            }
        }
        catch {
            Write-Error "Error processing tenant $($currentTenant.displayName):"
            Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
            Write-Error "Error Message: $($_.ErrorDetails.Message)"
            Write-Error "Activity ID: $($_.Exception.Response.Headers['RequestId'])"
            
            # Add the failed customer to the list
            $failedCustomers += [PSCustomObject]@{
                DisplayName = $currentTenant.displayName
                TenantId    = $currentTenant.customerId
                Error      = $_.Exception.Message
            }
            # Continue to next tenant without breaking the loop
        }
    }

    # Output the failed customers at the end
    if ($failedCustomers.Count -gt 0) {
        Write-Output "The following customers failed to process:"
        $failedCustomers | ForEach-Object {
            Write-Output "Customer: $($_.DisplayName), TenantId: $($_.TenantId), Error: $($_.Error)"
        }
    }
    else {
        Write-Output "All customers processed successfully."
    }
}
