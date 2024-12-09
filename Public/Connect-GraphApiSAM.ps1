function Connect-GraphApiSAM {
    [CmdletBinding()]
    Param
    (
        [parameter(Position = 0, Mandatory = $false)]
        [ValidateNotNullOrEmpty()][String]$ApplicationId,
         
        [parameter(Position = 1, Mandatory = $false)]
        [ValidateNotNullOrEmpty()][String]$ApplicationSecret,
         
        [parameter(Position = 2, Mandatory = $true)]
        [ValidateNotNullOrEmpty()][String]$TenantID,
 
        [parameter(Position = 3, Mandatory = $false)]
        [ValidateNotNullOrEmpty()][String]$RefreshToken,

        [parameter(Position = 4, Mandatory = $false)]
        [ValidateNotNullOrEmpty()][String]$Scope = "https://graph.microsoft.com/.default"
    )
    
    Write-Verbose "Removing old token if it exists"
    $Script:GraphHeader = $null
    Write-Verbose "Logging into Graph API"
    
    try {
        # Initialize auth body with validation
        $AuthBody = @{}
        
        if ($ApplicationId) {
            Write-Verbose "Using provided credentials"
            if ([string]::IsNullOrEmpty($ApplicationSecret) -or [string]::IsNullOrEmpty($RefreshToken)) {
                throw "ApplicationSecret and RefreshToken are required when ApplicationId is provided"
            }
            $AuthBody = @{
                client_id     = $ApplicationId.ToString()
                client_secret = $ApplicationSecret
                scope         = $Scope
                refresh_token = $RefreshToken
                grant_type    = "refresh_token"
            }
        }
        else {
            Write-Verbose "Using cached credentials"
            if (-not $global:ApplicationId -or -not $global:ApplicationSecret -or -not $global:RefreshToken) {
                throw "Cached credentials not found. Please provide ApplicationId, ApplicationSecret, and RefreshToken"
            }
            $AuthBody = @{
                client_id     = $global:ApplicationId.ToString()
                client_secret = $global:ApplicationSecret
                scope         = $Scope
                refresh_token = $global:RefreshToken
                grant_type    = "refresh_token"
            }
        }

        # Validate all required parameters are present
        foreach ($key in @('client_id', 'client_secret', 'refresh_token')) {
            if ([string]::IsNullOrEmpty($AuthBody[$key])) {
                throw "Missing required parameter: $key"
            }
        }

        $AccessToken = (Invoke-RestMethod -Method post -Uri "https://login.microsoftonline.com/$($tenantid)/oauth2/v2.0/token" -Body $Authbody -ErrorAction Stop).access_token
 
        $script:GraphHeader = @{ Authorization = "Bearer $($AccessToken)" }

        return $GraphHeader
    }
    catch {
        Write-Error "Could not log into the Graph API for tenant $($TenantID): $($_.Exception.Message)"
        throw
    }
}

