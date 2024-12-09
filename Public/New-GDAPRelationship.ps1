function New-GDAPRelationship {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 50)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$CustomerId,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+S)?)?$')]
        [ValidateScript({
            $duration = $_
            if ($duration -match '^P(\d+)Y') {
                [int]$years = $matches[1]
                if ($years -gt 2) { return $false }
            }
            return $true
        }, ErrorMessage = "Duration must be between P1D and P2Y inclusive")]
        [string]$Duration,

        [Parameter(Mandatory = $true)]
        [string[]]$AccessDetails,

        [Parameter(Mandatory = $false)]
        [ValidateSet('P0D', 'PT0S', 'P180D')]
        [string]$AutoExtendDuration = 'PT0S',

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing New-GDAPRelationship"
        
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

        # Function to get role template details
        function Get-RoleTemplates {
            param($GraphToken)
            
            try {
                $uri = "https://graph.microsoft.com/v1.0/directoryRoleTemplates"
                $roleTemplates = Invoke-RestMethod -Uri $uri -Headers $GraphToken -Method Get
                
                # Create a hashtable for quick lookups
                $roleMapping = @{}
                foreach ($role in $roleTemplates.value) {
                    $roleMapping[$role.id] = @{
                        DisplayName = $role.displayName
                        Description = $role.description
                    }
                }
                return $roleMapping
            }
            catch {
                Write-Warning "Failed to retrieve role templates: $_"
                return @{}
            }
        }

        # Get role templates once at the beginning
        $roleTemplates = Get-RoleTemplates -GraphToken $graphToken
    }

    process {
        try {
            # Create relationship request body
            $body = @{
                displayName = $DisplayName
                duration = $Duration
                accessDetails = @{
                    unifiedRoles = @(
                        foreach ($role in $AccessDetails) {
                            @{
                                roleDefinitionId = $role
                            }
                        }
                    )
                }
                autoExtendDuration = $AutoExtendDuration
            }

            # Add optional customer object if CustomerId is provided
            if ($CustomerId) {
                $body.customer = @{
                    tenantId = $CustomerId
                }
            }

            # Debug: Output the exact JSON being sent
            Write-Verbose "Request Body JSON:"
            Write-Verbose ($body | ConvertTo-Json -Depth 10)

            # Create relationship
            $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships"
            $jsonBody = $body | ConvertTo-Json -Depth 10
            $relationship = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Post -Body $jsonBody -ContentType 'application/json'

            # Lock for approval
            $lockUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($relationship.id)/requests"
            $lockBody = @{
                action = "lockForApproval"
            }
            $request = Invoke-RestMethod -Uri $lockUri -Headers $graphToken -Method Post -Body ($lockBody | ConvertTo-Json) -ContentType 'application/json'

            # Generate customer invitation link
            $invitationLink = "https://admin.microsoft.com/AdminPortal/Home#/partners/invitation/granularAdminRelationships/$($relationship.id)"
            
            # Transform the roles array to include full details
            $assignedRoles = $relationship.accessDetails.unifiedRoles | ForEach-Object {
                $roleId = $_.roleDefinitionId
                $roleInfo = $roleTemplates[$roleId]
                
                [PSCustomObject]@{
                    RoleId = $roleId
                    DisplayName = $roleInfo.DisplayName ?? "Unknown Role"
                    Description = $roleInfo.Description ?? "No description available"
                }
            }

            Write-Output ([PSCustomObject]@{
                RelationshipInfo = [PSCustomObject]@{
                    Id = $relationship.id
                    DisplayName = $relationship.displayName
                    Status = $relationship.status
                    Duration = $relationship.duration
                    AutoExtendDuration = $relationship.autoExtendDuration
                    Created = [DateTime]$relationship.createdDateTime
                    LastModified = [DateTime]$relationship.lastModifiedDateTime
                    Activated = if ($relationship.activatedDateTime) { [DateTime]$relationship.activatedDateTime } else { $null }
                    ExpiresOn = if ($relationship.endDateTime) { [DateTime]$relationship.endDateTime } else { $null }
                }
                CustomerInfo = if ($relationship.customer) {
                    [PSCustomObject]@{
                        TenantId = $relationship.customer.tenantId
                        DisplayName = $relationship.customer.displayName
                    }
                } else { $null }
                AccessRoles = $assignedRoles
                ApprovalStatus = [PSCustomObject]@{
                    RequestId = $request.id
                    Status = $request.status
                    Action = $request.action
                    RequestedOn = [DateTime]$request.createdDateTime
                    LastUpdated = [DateTime]$request.lastModifiedDateTime
                }
                InvitationLink = $invitationLink
            })
        }
        catch {
            Write-Error "Error creating GDAP relationship: $_"
            throw
        }
    }
}