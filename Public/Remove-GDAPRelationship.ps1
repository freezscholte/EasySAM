function Remove-GDAPRelationship {
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

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Remove-GDAPRelationship"
        
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
            # If Status is approvalPending, throw error early
            if ($Status -eq 'approvalPending') {
                throw "Cannot delete GDAP relationship with ID $RelationshipId because its status is 'approvalPending'. Only activated or terminated relationships can be deleted."
            }

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
                    if ($Status -eq 'approvalPending') {
                        throw "Cannot delete GDAP relationship with ID $RelationshipId because its status is 'approvalPending'. Only activated or terminated relationships can be deleted."
                    }
                }
            }
            
            # Add If-Match header to existing headers
            $deleteHeaders = $graphToken.Clone()
            $deleteHeaders['If-Match'] = $Etag

            # Delete relationship
            $deleteUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
            $response = Invoke-RestMethod -Uri $deleteUri -Headers $deleteHeaders -Method Delete
            
            # 204 No Content is success
            Write-Output "GDAP relationship with ID $RelationshipId has been successfully deleted."
        }
        catch {
            if ($_.Exception.Message -match "deletionOfRelationshipWithCurrentStatusNotAllowed") {
                Write-Error "Cannot delete GDAP relationship: The relationship must be activated or terminated before it can be deleted."
            }
            else {
                Write-Error "Error deleting GDAP relationship: $_"
            }
            throw
        }
    }
}