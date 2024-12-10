# First, define the Process-Template function
function Process-Template {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UseTemplate,
        [Parameter(Mandatory = $true)]
        [string]$RelationshipId,
        [Parameter(Mandatory = $true)]
        [hashtable]$GraphToken,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$SAMConfigObject
    )

    Write-Verbose "Loading role template: $UseTemplate"
    $templatesPath = Join-Path $PSScriptRoot ".." "Config" "accessTemplates.json"
    
    if (-not (Test-Path $templatesPath)) {
        throw "Access templates file not found at: $templatesPath"
    }

    $templates = Get-Content $templatesPath | ConvertFrom-Json
    
    if (-not $templates.templates.$UseTemplate) {
        throw "Template '$UseTemplate' not found in templates file"
    }

    # Get role definitions to map names
    $rolesUri = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions"
    $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $GraphToken -Method Get).value

    # Get approved roles for the relationship
    $relationshipUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
    $relationship = Invoke-RestMethod -Uri $relationshipUri -Headers $GraphToken -Method Get
    $approvedRoles = $relationship.accessDetails.unifiedRoles.roleDefinitionId

    # Create/validate groups and store their IDs
    $groupMappings = @{}
    foreach ($assignment in $templates.templates.$UseTemplate.roleAssignments) {
        if ($assignment.roleId -notin $approvedRoles) {
            $roleName = ($roles | Where-Object { $_.id -eq $assignment.roleId }).displayName
            Write-Error "Role '$roleName' (ID: $($assignment.roleId)) is not approved for this GDAP relationship"
            continue
        }

        try {
            $groupId = New-EntraGroupIfNotExists -GroupName $assignment.groupName -Description $assignment.description
            $groupMappings[$assignment.groupName] = $groupId
        }
        catch {
            Write-Error "Failed to create/validate group $($assignment.groupName): $_"
            continue
        }
    }

    # Create assignments for each role-group pair
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    foreach ($assignment in $templates.templates.$UseTemplate.roleAssignments) {
        $roleInfo = $roles | Where-Object { $_.id -eq $assignment.roleId }
        Write-Verbose "Processing assignment for role: $($roleInfo.displayName) to group: $($assignment.groupName)"
        
        try {
            # Verify the values before creating params
            $groupId = $groupMappings[$assignment.groupName]
            if (-not $groupId) {
                throw "Could not find group ID for group: $($assignment.groupName)"
            }
            
            if (-not $assignment.roleId) {
                throw "Role ID is missing for assignment to group: $($assignment.groupName)"
            }

            Write-Verbose "Using Group ID: $groupId"
            Write-Verbose "Using Role ID: $($assignment.roleId)"
            
            $params = @{
                RelationshipId    = $RelationshipId
                RoleDefinitionIds = @($assignment.roleId)
                EntraGroupId      = $groupId
                Action            = 'Create' # Force Create action for template processing
                SAMConfigObject   = $SAMConfigObject # Pass through the config object
            }
            
            Write-Verbose "Params for assignment creation:"
            Write-Verbose ($params | ConvertTo-Json)
            
            try {
                $result = Set-GDAPAccessAssignment @params
                
                # Add group details to the result object
                if ($result) {
                    $result | Add-Member -NotePropertyName 'GroupName' -NotePropertyValue $assignment.groupName -Force
                    $result | Add-Member -NotePropertyName 'GroupDescription' -NotePropertyValue $assignment.description -Force
                    $results.Add($result)
                }
            }
            catch {
                if ($_.Exception.Response.StatusCode -eq 409) {
                    Write-Verbose "Assignment already exists for group $($assignment.groupName), creating result object."
                    
                    # Create a result object for existing assignment
                    $result = [PSCustomObject]@{
                        Status         = "Exists"
                        Message       = "Assignment already exists"
                        SecurityGroup = [PSCustomObject]@{
                            Id          = $groupId
                            Name        = $assignment.groupName
                            Description = $assignment.description
                            Type        = "securityGroup"
                        }
                        AssignedRoles = @([PSCustomObject]@{
                            RoleId   = $assignment.roleId
                            RoleName = $roleInfo.displayName
                        })
                    }
                    $results.Add($result)
                    continue
                }
                else {
                    throw
                }
            }
        }
        catch {
            Write-Error "Failed to process assignment for role $($roleInfo.displayName) to group $($assignment.groupName): $_"
            continue # Skip to next assignment instead of throwing
        }
    }
    
    return $results
}

function Set-GDAPAccessAssignment {
    [CmdletBinding(DefaultParameterSetName = 'Create')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$RelationshipId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Update')]
        [Parameter(ParameterSetName = 'Template', Mandatory = $false)]
        [string[]]$RoleDefinitionIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Update')]
        [Parameter(ParameterSetName = 'Template', Mandatory = $false)]
        [string]$EntraGroupId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Update')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
        [string]$AssignmentId,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Create', 'Update', 'Remove')]
        [string]$Action = 'Create',

        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [string]$UseTemplate,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Set-GDAPAccessAssignment"
        
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
            throw "No SAM configuration found. Please provide SAMConfigObject or initialize global SAMConfig" 
        }

        try {
            $graphParams = @{
                ApplicationId     = $samConfig.ApplicationId
                ApplicationSecret = $samConfig.ApplicationSecret
                RefreshToken      = $samConfig.RefreshToken
                TenantId          = $samConfig.TenantId
            }
            $graphToken = Connect-GraphApiSAM @graphParams
        }
        catch {
            throw "Failed to connect to Graph API: $_"
        }

        # Helper function to create and validate Entra group
        function New-EntraGroupIfNotExists {
            param (
                [string]$GroupName,
                [string]$Description
            )

            Write-Verbose "Checking if group exists: $GroupName"
            
            # Check if group exists
            $groupFilter = [System.Web.HttpUtility]::UrlEncode("displayName eq '$GroupName'")
            $groupUri = "https://graph.microsoft.com/v1.0/groups?`$filter=$groupFilter"
            $existingGroup = (Invoke-RestMethod -Uri $groupUri -Headers $graphToken -Method Get).value

            if ($existingGroup) {
                Write-Verbose "Group already exists: $GroupName"
                return $existingGroup[0].id
            }

            Write-Verbose "Creating new group: $GroupName"
            $newGroupBody = @{
                displayName     = $GroupName
                description     = $Description
                mailEnabled     = $false
                securityEnabled = $true
                mailNickname    = ($GroupName -replace '[^a-zA-Z0-9]', '')
            }

            $createUri = "https://graph.microsoft.com/v1.0/groups"
            $newGroup = Invoke-RestMethod -Uri $createUri -Headers $graphToken -Method Post -Body ($newGroupBody | ConvertTo-Json) -ContentType 'application/json'
            
            # Wait for group to be available
            $maxAttempts = 30
            $attempts = 0
            $groupId = $newGroup.id
            
            while ($attempts -lt $maxAttempts) {
                try {
                    $checkUri = "https://graph.microsoft.com/v1.0/groups/$groupId"
                    $null = Invoke-RestMethod -Uri $checkUri -Headers $graphToken -Method Get
                    Write-Verbose "Group is now available: $GroupName"
                    return $groupId
                }
                catch {
                    $attempts++
                    if ($attempts -eq $maxAttempts) {
                        throw "Timeout waiting for group to become available: $GroupName"
                    }
                    Write-Verbose "Waiting for group to become available (Attempt $attempts of $maxAttempts)"
                    Start-Sleep -Seconds 2
                }
            }
        }
    }

    process {
        try {
            # Verify relationship status
            $relationshipUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId"
            $relationship = Invoke-RestMethod -Uri $relationshipUri -Headers $graphToken -Method Get

            if ($relationship.status -ne 'active') {
                throw "GDAP relationship must be active to manage access assignments. Current status: $($relationship.status)"
            }

            # Handle template processing as a separate flow
            if ($UseTemplate) {
                Write-Verbose "Processing template: $UseTemplate"
                return Process-Template -UseTemplate $UseTemplate -RelationshipId $RelationshipId -GraphToken $graphToken -SAMConfigObject $SAMConfigObject
            }

            # Regular processing for Create/Update/Remove actions
            switch ($Action) {
                'Create' {
                    # Skip validation if using template
                    if (-not $PSBoundParameters.ContainsKey('UseTemplate')) {
                        # Validate parameters for Create
                        if (-not $EntraGroupId) {
                            throw "EntraGroupId is required and cannot be empty for Create action."
                        }
                        if (-not $RoleDefinitionIds -or $RoleDefinitionIds.Count -eq 0) {
                            throw "RoleDefinitionIds are required and cannot be empty for Create action."
                        }
                    }

                    Write-Verbose "Creating new access assignments"
                    Write-Verbose "EntraGroupId: $EntraGroupId"
                    Write-Verbose "RoleDefinitionIds count: $($RoleDefinitionIds.Count)"
                    Write-Verbose "RoleDefinitionIds values: $($RoleDefinitionIds | ConvertTo-Json)"
                    
                    # Create the roles array using Generic List
                    $unifiedRoles = [System.Collections.Generic.List[hashtable]]::new()
                    
                    foreach ($roleId in $RoleDefinitionIds) {
                        Write-Verbose "Processing roleId: $roleId"
                        if ([string]::IsNullOrEmpty($roleId)) {
                            Write-Warning "Empty roleId detected in RoleDefinitionIds"
                            continue
                        }
                        $unifiedRoles.Add(@{
                            roleDefinitionId = $roleId
                        })
                    }

                    Write-Verbose "Created unified roles: $($unifiedRoles | ConvertTo-Json)"

                    if (-not $unifiedRoles) {
                        throw "No valid role definitions were provided"
                    }

                    if (-not $EntraGroupId) {
                        throw "EntraGroupId is empty when creating request body"
                    }
                    
                    $body = @{
                        accessDetails   = @{
                            unifiedRoles = $unifiedRoles.ToArray()
                        }
                        accessContainer = @{
                            accessContainerId   = $EntraGroupId
                            accessContainerType = "securityGroup"
                        }
                    }

                    Write-Verbose "Created request body:"
                    Write-Verbose ($body | ConvertTo-Json -Depth 20)
                    
                    $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments"
                    try {
                        $response = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Post -Body ($body | ConvertTo-Json -Depth 20) -ContentType 'application/json'
                    }
                    catch {
                        if ($_.Exception.Response.StatusCode -eq 409) {
                            Write-Verbose "Assignment already exists, skipping creation."
                            throw # Re-throw to handle in the template processing
                        }
                        else {
                            Write-Error "Failed to create assignment. Request body was: $($body | ConvertTo-Json -Depth 20)"
                            throw $_
                        }
                    }
                    
                    # Get group details
                    $groupUri = "https://graph.microsoft.com/v1.0/groups/$EntraGroupId"
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

                    # Get role definitions
                    $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
                    $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $graphToken -Method Get).value

                    return [PSCustomObject]@{
                        AssignmentId         = $response.id
                        Status               = $response.status
                        CreatedDateTime      = $response.createdDateTime
                        LastModifiedDateTime = $response.lastModifiedDateTime
                        SecurityGroup        = [PSCustomObject]@{
                            Id          = $EntraGroupId
                            Name        = $groupName
                            Description = $groupDescription
                            Type        = "securityGroup"
                        }
                        AssignedRoles        = $RoleDefinitionIds | ForEach-Object {
                            $roleId = $_
                            $roleName = ($roles | Where-Object { $_.id -eq $roleId }).displayName
                            if ($roleName) {
                                [PSCustomObject]@{
                                    RoleId   = $roleId
                                    RoleName = $roleName
                                }
                            }
                        }
                    }
                }

                'Update' {
                    # Skip validation if using template
                    if (-not $PSBoundParameters.ContainsKey('UseTemplate')) {
                        # Validate parameters for Update
                        if (-not $AssignmentId) {
                            throw "AssignmentId is required for update operations"
                        }
                        if (-not $EntraGroupId) {
                            throw "EntraGroupId is required and cannot be empty for Update action."
                        }
                        if (-not $RoleDefinitionIds -or $RoleDefinitionIds.Count -eq 0) {
                            throw "RoleDefinitionIds are required and cannot be empty for Update action."
                        }
                    }

                    Write-Verbose "Updating access assignment: $AssignmentId"
                    
                    # First get the current assignment to get its ETag
                    $getUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments/$AssignmentId"
                    $currentAssignment = Invoke-RestMethod -Uri $getUri -Headers $graphToken -Method Get
                    
                    # Add If-Match header with ETag
                    $updateHeaders = $graphToken.Clone()
                    $updateHeaders["If-Match"] = $currentAssignment.'@odata.etag'

                    $body = @{
                        accessDetails = @{
                            unifiedRoles = @(
                                foreach ($roleId in $RoleDefinitionIds) {
                                    @{
                                        roleDefinitionId = $roleId
                                    }
                                }
                            )
                        }
                    }

                    $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments/$AssignmentId"
                    $null = Invoke-RestMethod -Uri $uri -Headers $updateHeaders -Method Patch -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    
                    # Get updated assignment details
                    $updatedAssignment = Invoke-RestMethod -Uri $getUri -Headers $graphToken -Method Get
    
                    # Get group details
                    $groupUri = "https://graph.microsoft.com/v1.0/groups/$EntraGroupId"
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

                    # Get role definitions
                    $rolesUri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
                    $roles = (Invoke-RestMethod -Uri $rolesUri -Headers $graphToken -Method Get).value

                    return [PSCustomObject]@{
                        AssignmentId         = $updatedAssignment.id
                        Status               = $updatedAssignment.status
                        CreatedDateTime      = $updatedAssignment.createdDateTime
                        LastModifiedDateTime = $updatedAssignment.lastModifiedDateTime
                        SecurityGroup        = [PSCustomObject]@{
                            Id          = $EntraGroupId
                            Name        = $groupName
                            Description = $groupDescription
                            Type        = "securityGroup"
                        }
                        AssignedRoles        = $RoleDefinitionIds | ForEach-Object {
                            $roleId = $_
                            $roleName = ($roles | Where-Object { $_.id -eq $roleId }).displayName
                            if ($roleName) {
                                [PSCustomObject]@{
                                    RoleId   = $roleId
                                    RoleName = $roleName
                                }
                            }
                        }
                    }
                }

                'Remove' {
                    # Validate parameters for Remove
                    if (-not $AssignmentId) {
                        throw "AssignmentId is required for remove operations"
                    }

                    Write-Verbose "Removing access assignment: $AssignmentId"
                    
                    # First get the current assignment to get its ETag
                    $getUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments/$AssignmentId"
                    $currentAssignment = Invoke-RestMethod -Uri $getUri -Headers $graphToken -Method Get
                    
                    # Add If-Match header with ETag
                    $deleteHeaders = $graphToken.Clone()
                    $deleteHeaders["If-Match"] = $currentAssignment.'@odata.etag'

                    $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/accessAssignments/$AssignmentId"
                    $null = Invoke-RestMethod -Uri $uri -Headers $deleteHeaders -Method Delete
                    
                    return [PSCustomObject]@{
                        AssignmentId = $AssignmentId
                        Status       = "Removed"
                        Message      = "Successfully removed access assignment"
                    }
                }
            }
        }
        catch {
            $errorResponse = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorResponse.error.message) {
                $errorResponse.error.message
            }
            else {
                $_.Exception.Message
            }
            Write-Error "Failed to $Action access assignment: $errorMessage"
            throw
        }
    }
}