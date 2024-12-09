function Remove-GDAPRoleAssignment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RelationshipId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentId,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Remove-GDAPRoleAssignment"
        
        # Initialize SAM configuration
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
            # Delete role assignment
            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments/$AssignmentId"
            Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Delete
            Write-Output "GDAP role assignment with ID $AssignmentId has been successfully deleted."
        }
        catch {
            Write-Error "Error deleting GDAP role assignment: $_"
            throw
        }
    }
}