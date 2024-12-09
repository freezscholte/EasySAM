function Deny-GDAPRelationship {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory = $true,
            ValueFromPipelineByPropertyName = $true
        )]
        [string]$RelationshipId,

        [Parameter(
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true
        )]
        [string]$Etag,

        [Parameter(
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true
        )]
        [string]$Status,

        [Parameter(
            Mandatory = $true
        )]
        [string]$RejectReason,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Deny-GDAPRelationship"
        
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
            # If Etag or Status is not provided, get them from the API
            if (-not $Etag -or -not $Status) {
                Write-Verbose "Retrieving relationship details from API"
                $getUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
                $relationship = Invoke-RestMethod -Uri $getUri -Headers $graphToken -Method Get
                
                if (-not $Etag) {
                    $Etag = $relationship.'@odata.etag'
                }
                if (-not $Status) {
                    $Status = $relationship.status
                }
            }

            # Verify the relationship is in approvalPending status
            if ($Status -ne 'approvalPending') {
                throw "Cannot reject GDAP relationship with ID $RelationshipId because its status is '$Status'. Only relationships with 'approvalPending' status can be rejected."
            }

            # Add If-Match header to existing headers
            $patchHeaders = $graphToken.Clone()
            $patchHeaders['If-Match'] = $Etag
            $patchHeaders['Content-Type'] = 'application/json'

            # Prepare the request body
            $body = @{
                status = "terminated"
                terminationReason = $RejectReason
            } | ConvertTo-Json

            # Reject the relationship
            $patchUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/"
            $response = Invoke-RestMethod -Uri $patchUri -Headers $patchHeaders -Method Patch -Body $body
            
            Write-Output "GDAP relationship with ID $RelationshipId has been successfully rejected."
        }
        catch {
            Write-Error "Error rejecting GDAP relationship: $_"
            throw
        }
    }
}