function Invoke-NewSAM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$ConfigurePreconsent,
        
        [Parameter(Mandatory = $false)]
        [string]$DisplayName,
        
        [Parameter(Mandatory = $false)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [switch]$ExportConfig
    )

    begin {
        Write-Verbose "=== Begin Block: Invoke-NewSAM ==="
        $ErrorActionPreference = "Stop"
        Write-Output "Starting Invoke-NewSAM..."

        # Required Microsoft Graph permissions
        Write-Verbose "Setting up required scopes..."
        $requiredScopes = @(
            "Application.ReadWrite.All",
            "Directory.ReadWrite.All",
            "Directory.AccessAsUser.All"
        )

        Write-Verbose "Setting up required modules..."
        $requiredModules = @(
            'Microsoft.Graph.Authentication'
            'Microsoft.Graph.Applications'
            'Microsoft.Graph.Groups'
            'Microsoft.Graph.Users'
        )

        foreach ($module in $requiredModules) {
            Write-Verbose "Processing module: $module"
            if (-not (Get-Module -ListAvailable -Name $module)) {
                Write-Output "Installing $module..."
                Install-Module -Name $module -Force -AllowClobber -Repository PSGallery -Scope CurrentUser
            }
            Write-Output "Importing $module..."
            Import-Module -Name $module -Force
        }

        Write-Verbose "Disconnecting existing Graph sessions..."
        Disconnect-MgGraph -ErrorAction SilentlyContinue

        # Get the permissions configuration early
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Config\samPermissions.json"
        Write-Verbose "Reading permissions configuration from: $configPath"
        
        if (-not (Test-Path -Path $configPath)) {
            throw "Permissions configuration file not found at: $configPath"
        }

        $permissionsConfig = Get-Content -Path $configPath -Raw | ConvertFrom-Json

        # Override parameters with config values if not provided
        if (-not $DisplayName) {
            $DisplayName = $permissionsConfig.defaultSettings.displayName
            Write-Verbose "Using display name from config: $DisplayName"
        }

        if (-not $TenantId) {
            $TenantId = $permissionsConfig.defaultSettings.tenantId
            Write-Verbose "Using tenant ID from config: $TenantId"
        }
    }

    process {
        Write-Verbose "=== Process Block: Invoke-NewSAM ==="
        try {
            Write-Verbose "Initiating Graph connection..."
            
            if ([string]::IsNullOrEmpty($TenantId)) {
                Write-Verbose "No TenantId provided in parameters or config, using default..."
                Connect-MgGraph -Scopes $requiredScopes
                $TenantId = (Get-MgContext).TenantId
                Write-Verbose "Connected to tenant: $TenantId"
            }
            else {
                Write-Verbose "Connecting to specified tenant: $TenantId"
                Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes
            }

            Write-Verbose "Creating application parameters..."
            
            try {
                # Create base application parameters
                $appParams = @{
                    DisplayName = $DisplayName
                    SignInAudience = "AzureADMultipleOrgs"
                    Web = @{
                        RedirectUris = @(
                            "urn:ietf:wg:oauth:2.0:oob",
                            "https://localhost",
                            "http://localhost",
                            "http://localhost:8400"
                        )
                    }
                    RequiredResourceAccess = @()
                }

                # Create a hashtable to store permissions by ResourceAppId
                $resourcePermissions = @{}

                # Process application grants (delegated permissions)
                foreach ($grant in $permissionsConfig.applicationGrants) {
                    if (-not $resourcePermissions[$grant.enterpriseApplicationId]) {
                        $resourcePermissions[$grant.enterpriseApplicationId] = @()
                    }
                    
                    foreach ($permissionName in ($grant.scope -split ',')) {
                        $permission = Get-PermissionId -ResourceAppId $grant.enterpriseApplicationId -PermissionName $permissionName.Trim()
                        # Only add if not already present
                        if (-not ($resourcePermissions[$grant.enterpriseApplicationId] | Where-Object { $_.Id -eq $permission.Id })) {
                            $resourcePermissions[$grant.enterpriseApplicationId] += $permission
                        }
                    }
                }

                # Process application roles
                foreach ($role in $permissionsConfig.appRoles) {
                    if (-not $resourcePermissions[$role.enterpriseApplicationId]) {
                        $resourcePermissions[$role.enterpriseApplicationId] = @()
                    }
                    
                    foreach ($permissionName in ($role.role -split ',')) {
                        $permission = Get-PermissionId -ResourceAppId $role.enterpriseApplicationId -PermissionName $permissionName.Trim()
                        # Only add if not already present
                        if (-not ($resourcePermissions[$role.enterpriseApplicationId] | Where-Object { $_.Id -eq $permission.Id })) {
                            $resourcePermissions[$role.enterpriseApplicationId] += $permission
                        }
                    }
                }

                # Convert the hashtable to RequiredResourceAccess format
                foreach ($resourceAppId in $resourcePermissions.Keys) {
                    $appParams.RequiredResourceAccess += @{
                        ResourceAppId = $resourceAppId
                        ResourceAccess = $resourcePermissions[$resourceAppId]
                    }
                }

                Write-Verbose "Creating application with parameters:"
                Write-Verbose ($appParams | ConvertTo-Json -Depth 10)

                $app = New-MgApplication @appParams
                
                if (-not $app -or -not $app.AppId) {
                    throw "Application creation failed or AppId is missing"
                }
                Write-Verbose "Application created with ID: $($app.AppId)"

                Write-Verbose "Creating service principal..."
                $spn = New-MgServicePrincipal -AppId $app.AppId -DisplayName $DisplayName
                Write-Verbose "Service principal created with ID: $($spn.Id)"

                Write-Verbose "Creating application secret..."
                $secretParams = @{
                    PasswordCredential = @{
                        DisplayName = "Secure Application Model Secret"
                    }
                }
                $secret = Add-MgApplicationPassword -ApplicationId $app.Id -BodyParameter $secretParams
                Write-Verbose "Secret created successfully"

                Write-Verbose "Waiting for application registration to propagate..."

                # Initial delay
                Start-Sleep -Seconds 3

                # Verify app registration is available
                $maxAttempts = 3
                $attempt = 0
                $delay = 5

                while ($attempt -lt $maxAttempts) {
                    try {
                        Write-Verbose "Verifying application registration (Attempt $($attempt + 1)/$maxAttempts)..."
                        $appCheck = Get-MgApplication -Filter "AppId eq '$($app.AppId)'"
                        if ($appCheck) {
                            Write-Verbose "Application registration verified successfully"
                            break
                        }
                    }
                    catch {
                        Write-Verbose "Verification attempt $($attempt + 1) failed: $($_.Exception.Message)"
                    }
                    
                    $attempt++
                    if ($attempt -lt $maxAttempts) {
                        Write-Verbose "Waiting $delay seconds before next attempt..."
                        Start-Sleep -Seconds $delay
                    }
                }

                if ($attempt -eq $maxAttempts) {
                    throw "Application registration verification failed after $maxAttempts attempts"
                }

                # Additional delay to allow for full propagation
                Write-Verbose "Waiting for application registration to fully propagate..."
                Start-Sleep -Seconds 10

                # Configure tokens
                Write-Output "Configuring access tokens..."
                
                # Get Partner Center token
                Write-Verbose "Getting Partner Center token..."
                $pcParams = @{
                    tenantId = $TenantId
                    ApplicationId = $app.AppId
                    ApplicationSecret = $secret.SecretText
                    scope = "https://api.partnercenter.microsoft.com/user_impersonation"
                }
                $pcTokenResponse = Get-PartnerSAMTokens @pcParams

                # Get Azure token
                Write-Verbose "Getting Azure token..."
                $azureParams = @{
                    tenantId = $TenantId
                    ApplicationId = $app.AppId
                    ApplicationSecret = $secret.SecretText
                    scope = "https://management.azure.com/user_impersonation"
                }
                $azureTokenResponse = Get-PartnerSAMTokens @azureParams

                # Set global-level variables
                Write-Verbose "Setting global-level variables..."
                $global:SAMConfig = [PSCustomObject]@{
                    DisplayName = $DisplayName
                    ApplicationId = $app.AppId
                    ApplicationSecret = $secret.SecretText
                    TenantId = $spn.AppOwnerOrganizationId
                    RefreshToken = $pcTokenResponse.refresh_token
                    AzureRefreshToken = $azureTokenResponse.refresh_token
                    CreatedOn = (Get-Date).ToString('o')
                    PCTokenExpiration = @{
                        ExpiresIn = [Int64]$pcTokenResponse.expires_in
                        ExpiresOn = [Int64]$pcTokenResponse.expires_on
                        NotBefore = [Int64]$pcTokenResponse.not_before
                    }
                    AzureTokenExpiration = @{
                        ExpiresIn = [Int64]$azureTokenResponse.expires_in
                        ExpiresOn = [Int64]$azureTokenResponse.expires_on
                        NotBefore = [Int64]$azureTokenResponse.not_before
                    }
                }

                # Output section
                Write-Output "`n######### Secure Application Model Details #########"
                Write-Output "ApplicationId         = '$($global:SAMConfig.ApplicationId)'"
                Write-Output "ApplicationSecret     = '$($global:SAMConfig.ApplicationSecret)'"
                Write-Output "TenantID             = '$($global:SAMConfig.TenantId)'"
                Write-Output "RefreshToken         = '$($global:SAMConfig.RefreshToken)'"
                Write-Output "AzureRefreshToken    = '$($global:SAMConfig.AzureRefreshToken)'"
                Write-Output "`nToken Expiration Details:"
                Write-Output "PC Token Valid From   = '$(ConvertFrom-UnixTime $global:SAMConfig.PCTokenExpiration.NotBefore)'"
                Write-Output "PC Token Expires      = '$(ConvertFrom-UnixTime $global:SAMConfig.PCTokenExpiration.ExpiresOn)'"
                Write-Output "Azure Token Valid From= '$(ConvertFrom-UnixTime $global:SAMConfig.AzureTokenExpiration.NotBefore)'"
                Write-Output "Azure Token Expires   = '$(ConvertFrom-UnixTime $global:SAMConfig.AzureTokenExpiration.ExpiresOn)'"
                Write-Output "#############################################"

                Write-Verbose "Returning results..."
                
                # Display admin consent URL if ConfigurePreconsent is specified
                if ($ConfigurePreconsent) {
                    $PreConsentUrl = "https://login.microsoftonline.com/$($global:SAMConfig.TenantId)/adminConsent?client_id=$($global:SAMConfig.ApplicationId)"
                    Start-Process $PreConsentUrl
                    Write-Output "`n######### Admin Consent URL #########"
                    Write-Output "Please complete the admin consent by visiting, the page did not open automatically:"
                    Write-Output $PreConsentUrl
                    Write-Output "###################################"

                }

                if ($ExportConfig) {
                    #Export the Samconfig to a file if set to $true
                    $global:SAMConfig | ConvertTo-Json -Depth 10 | Out-File "$PSScriptRoot\Config\existingSAM.json"
                }
                
                #Return the Samconfig to the console
                return $global:SAMConfig
                
            }
            catch {
                Write-Error "Failed to create application: $_"
                throw
            }
        }
        catch {
            Write-Error "An error occurred in Invoke-NewSAM: $($_.Exception.Message)"
            throw
        }
    }
}







