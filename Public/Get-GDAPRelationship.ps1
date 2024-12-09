function Get-GDAPRelationship {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$RelationshipId,

        [Parameter(Mandatory = $false)]
        [switch]$IncludePending,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Get-GDAPRelationship"
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
            if ($RelationshipId) {
                # Get specific relationship
                $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
                $relationship = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get
                
                # Get role definitions to map IDs to names
                $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
                $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $graphToken -Method Get).value

                # Create enhanced output object - remove .value since single relationship doesn't have it
                $enhancedRelationship = $relationship | Select-Object -Property `
                    @{Name='RelationshipId';Expression={$_.id}},
                    @{Name='DisplayName';Expression={$_.displayName}},
                    @{Name='Status';Expression={$_.status}},
                    @{Name='CustomerName';Expression={$_.customer.displayName}},
                    @{Name='CustomerTenantId';Expression={$_.customer.tenantId}},
                    @{Name='StartDate';Expression={$_.activatedDateTime}},
                    @{Name='EndDate';Expression={$_.endDateTime}},
                    @{Name='AssignedRoles';Expression={
                        $_.accessDetails.unifiedRoles | ForEach-Object {
                            $roleId = $_.roleDefinitionId
                            $roleName = ($roles | Where-Object { $_.id -eq $roleId }).displayName
                            if ($roleName) {
                                [PSCustomObject]@{
                                    RoleId = $roleId
                                    RoleName = $roleName
                                }
                            }
                        }
                    }}

                return $enhancedRelationship
            }
            else {
                # Similar enhancement for listing all relationships
                $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships"
                $relationships = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get
                
                # Get role definitions to map IDs to names
                $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
                $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $graphToken -Method Get).value

                # Create enhanced output objects
                $enhancedRelationships = $relationships.value | Select-Object -Property `
                    @{Name='RelationshipId';Expression={$_.id}},
                    @{Name='DisplayName';Expression={$_.displayName}},
                    @{Name='Status';Expression={$_.status}},
                    @{Name='CustomerName';Expression={$_.customer.displayName}},
                    @{Name='CustomerTenantId';Expression={$_.customer.tenantId}},
                    @{Name='StartDate';Expression={$_.activatedDateTime}},
                    @{Name='EndDate';Expression={$_.endDateTime}},
                    @{Name='AssignedRoles';Expression={
                        $_.accessDetails.unifiedRoles | ForEach-Object {
                            $roleId = $_.roleDefinitionId
                            $roleName = ($roles | Where-Object { $_.id -eq $roleId }).displayName
                            if ($roleName) {
                                [PSCustomObject]@{
                                    RoleId = $roleId
                                    RoleName = $roleName
                                }
                            }
                        }
                    }}

                return $enhancedRelationships
            }
        }
        catch {
            Write-Error "Error retrieving GDAP relationships: $_"
            throw
        }
    }
}