function New-GDAPRoleAssignment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RelationshipId,

        [Parameter(Mandatory = $true)]
        [string]$RoleId,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing New-GDAPRoleAssignment"
        
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
            # Create role assignment
            $body = @{
                roleDefinitionId = $RoleId
                principalId = $PrincipalId
            }

            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments"
            $assignment = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Post -Body ($body | ConvertTo-Json) -ContentType 'application/json'
            Write-Output $assignment
        }
        catch {
            Write-Error "Error creating GDAP role assignment: $_"
            throw
        }
    }
}