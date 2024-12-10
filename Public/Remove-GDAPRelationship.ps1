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
            # Get current relationship details if not provided
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

            # Handle different statuses
            switch ($Status) {
                'approvalPending' {
                    Write-Error "Cannot delete or terminate a relationship in 'approvalPending' status. It will automatically expire after 90 days if not approved."
                    return
                }
                'active' {
                    Write-Verbose "Relationship status is 'active'. Creating termination request."
                    $terminateUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/requests"
                    $terminateBody = @{
                        action = "terminate"
                    } | ConvertTo-Json

                    $terminateResponse = Invoke-RestMethod -Uri $terminateUri -Headers $graphToken -Method Post -Body $terminateBody -ContentType 'application/json'
                    Write-Verbose "Termination request created. Waiting for termination to complete. $terminateResponse"
                    
                    # Wait for termination to complete with timeout
                    $timeout = (Get-Date).AddMinutes(5)
                    do {
                        Start-Sleep -Seconds 5
                        $relationship = Invoke-RestMethod -Uri $getUri -Headers $graphToken -Method Get
                        $Status = $relationship.status
                        $Etag = $relationship.'@odata.etag'
                        Write-Verbose "Current status: $Status"
                        
                        if ((Get-Date) -gt $timeout) {
                            Write-Error "Timeout waiting for termination to complete"
                            return
                        }
                    } while ($Status -ne 'terminated')
                }
                'terminated' {
                    Write-Verbose "Relationship is already terminated. Proceeding with deletion."
                }
                default {
                    Write-Error "Unexpected relationship status: $Status"
                    return
                }
            }

            # Add required headers for deletion
            $deleteHeaders = @{
                Authorization = $graphToken.Authorization
                'If-Match' = $Etag
                'Content-Type' = 'application/json'
            }

            # Attempt deletion
            try {
                $deleteUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
                $null = Invoke-RestMethod -Uri $deleteUri -Headers $deleteHeaders -Method Delete
                Write-Output "GDAP relationship with ID $RelationshipId has been successfully deleted."
            }
            catch {
                $errorResponse = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                Write-Error "Failed to delete relationship: $($errorResponse.error.message)"
                throw
            }
        }
        catch {
            Write-Error "Error managing GDAP relationship: $_"
            throw
        }
    }
}