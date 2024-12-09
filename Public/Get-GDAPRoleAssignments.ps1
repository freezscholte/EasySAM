function Get-GDAPRoleAssignments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RelationshipId,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Get-GDAPRoleAssignments"
        
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
            # List role assignments
            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments"
            $assignments = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get

            # Get role definitions to map IDs to names
            $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
            $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $graphToken -Method Get).value

            # Create enhanced output objects
            $enhancedAssignments = $assignments.value | ForEach-Object {
                $assignment = $_
                
                # Get security group details
                $groupUri = "https://graph.microsoft.com/v1.0/groups/$($assignment.accessContainer.accessContainerId)"
                try {
                    $groupDetails = Invoke-RestMethod -Uri $groupUri -Headers $graphToken -Method Get
                    $groupName = $groupDetails.displayName
                    $groupDescription = $groupDetails.description
                }
                catch {
                    Write-Verbose "Could not retrieve group details: $_"
                    $groupName = "Unknown"
                    $groupDescription = "Could not retrieve group details"
                }

                # Create output object
                [PSCustomObject]@{
                    AssignmentId = $assignment.id
                    Status = $assignment.status
                    CreatedDateTime = $assignment.createdDateTime
                    LastModifiedDateTime = $assignment.lastModifiedDateTime
                    SecurityGroup = [PSCustomObject]@{
                        Id = $assignment.accessContainer.accessContainerId
                        Name = $groupName
                        Description = $groupDescription
                        Type = $assignment.accessContainer.accessContainerType
                    }
                    AssignedRoles = $assignment.accessDetails.unifiedRoles | ForEach-Object {
                        $roleId = $_.roleDefinitionId
                        $roleName = ($roles | Where-Object { $_.id -eq $roleId }).displayName
                        if ($roleName) {
                            [PSCustomObject]@{
                                RoleId = $roleId
                                RoleName = $roleName
                            }
                        }
                    }
                }
            }

            return $enhancedAssignments
        }
        catch {
            Write-Error "Error retrieving GDAP role assignments: $_"
            throw
        }
    }
}