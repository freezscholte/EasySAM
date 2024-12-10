function Get-GDAPServiceManagementDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CustomerId,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Get-GDAPServiceManagementDetails"
        # Initialize SAM configuration
        $samConfig = if ($SAMConfigObject) { 
            Write-Verbose "Using provided SAM configuration object"
            $SAMConfigObject 
        }
        elseif ($global:SAMConfig) { 
            Write-Verbose "Using existing SAM configuration"
            $global:SAMConfig 
        }
        else { 
            throw "SAM configuration not found. Please run Invoke-NewSAM first or provide a configuration." 
        }

        # Connect to Graph API
        try {
            Write-Verbose "$($samConfig.ApplicationId) - $($samConfig.TenantId)"
            $graphParams = @{
                ApplicationId = $samConfig.ApplicationId
                ApplicationSecret = $samConfig.ApplicationSecret
                RefreshToken = $samConfig.RefreshToken
                TenantId = $samConfig.TenantId
            }
            $graphToken = Connect-GraphApiSAM @graphParams
        }
        catch {
            throw "Failed to connect to Graph API: $_"
        }
    }

    process {
        try {
            # Get service management details
            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminCustomers/$CustomerId/serviceManagementDetails"
            $serviceDetails = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get

            # Create enhanced output objects
            $enhancedServiceDetails = $serviceDetails.value | Select-Object -Property `
                @{Name='ServiceName';Expression={$_.serviceName}},
                @{Name='ServiceId';Expression={$_.serviceId}},
                @{Name='ManagementUrl';Expression={$_.serviceManagementUrl}},
                @{Name='ServiceDescription';Expression={$_.serviceDescription}}

            return $enhancedServiceDetails
        }
        catch {
            Write-Error "Error retrieving GDAP service management details: $_"
            throw
        }
    }
}
