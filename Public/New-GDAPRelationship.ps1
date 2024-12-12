<#
.SYNOPSIS
Creates a new Granular Delegated Admin Privilege (GDAP) relationship in Microsoft 365.

.DESCRIPTION
The New-GDAPRelationship cmdlet creates a new GDAP relationship between a partner tenant and a customer tenant in Microsoft 365. 
It allows partners to define granular administrative privileges with specific roles, duration, and auto-extension settings.

.PARAMETER DisplayName
The display name for the GDAP relationship. Must be between 1 and 50 characters.

.PARAMETER CustomerId
The tenant ID of the customer organization. If not provided, the relationship will be created without a specific customer association.

.PARAMETER Duration
The duration of the GDAP relationship in ISO 8601 duration format. Must be between 1 day (P1D) and 2 years (P2Y).
Examples: P30D (30 days), P1Y (1 year), P1Y6M (1 year and 6 months)

.PARAMETER AccessDetails
An array of role definition IDs that specify the administrative privileges to be granted.

.PARAMETER UseTemplate
The template name to use for the GDAP relationship. Valid values are:
- 'Standard'
- 'ReadOnly'

.PARAMETER AutoExtendDuration
The duration for automatic extension of the relationship. Valid values are:
- 'P0D' (No auto-extension)
- 'PT0S' (No auto-extension)
- 'P180D' (180 days auto-extension)
Default value is 'PT0S'.

.PARAMETER SAMConfigObject
A custom configuration object containing authentication details. If not provided, the function will use the global SAM configuration.

.OUTPUTS
Returns a custom object containing:
- RelationshipId: The unique identifier of the created relationship
- DisplayName: The display name of the relationship
- Status: Current status of the relationship
- CustomerInfo: Customer tenant details (if CustomerId was provided)
- AccessRoles: Detailed information about the assigned roles
- ApprovalStatus: Information about the approval request
- Operation: Details about the creation operation
- InvitationLink: URL for customer to approve the relationship

.EXAMPLE
$roleIds = @("f2ef992c-3afb-46b9-b7cf-a126ee74c451", "729827e3-9c14-49f7-bb1b-9608f156bbb8")
New-GDAPRelationship -DisplayName "Contoso Support Access" -Duration "P90D" -AccessDetails $roleIds

Creates a new GDAP relationship named "Contoso Support Access" with a 90-day duration and specified roles.

.EXAMPLE
$config = @{
    ApplicationId = "12345678-1234-1234-1234-123456789012"
    ApplicationSecret = "your-secret"
    RefreshToken = "your-refresh-token"
    TenantId = "partner-tenant-id"
}
$samConfig = [PSCustomObject]$config
New-GDAPRelationship -DisplayName "Customer Admin Access" -CustomerId "customer-tenant-id" -Duration "P1Y" -AccessDetails $roleIds -SAMConfigObject $samConfig

Creates a new GDAP relationship with a custom SAM configuration, specific customer ID, and one-year duration.

.EXAMPLE
New-GDAPRelationship -DisplayName "Auto-Extending Access" -Duration "P30D" -AccessDetails $roleIds -AutoExtendDuration "P180D"

Creates a new GDAP relationship that will automatically extend for 180 days after the initial 30-day period.

.NOTES
- Requires appropriate Microsoft Partner Center and Microsoft 365 permissions
- The Duration parameter must follow ISO 8601 duration format
- Role definition IDs can be obtained from Microsoft Graph API documentation
- The function requires valid SAM configuration either globally or provided as parameter

.LINK
https://learn.microsoft.com/en-us/partner-center/gdap-introduction
#>
function New-GDAPRelationship {
    [CmdletBinding(DefaultParameterSetName = 'Manual')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [ValidateLength(1, 50)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false, ParameterSetName = 'Manual')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Template')]
        [string]$CustomerId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
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

        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')]
        [string[]]$AccessDetails,

        [Parameter(Mandatory = $true, ParameterSetName = 'Template')]
        [ValidateSet('Standard', 'ReadOnly')]
        [string]$UseTemplate,

        [Parameter(Mandatory = $false, ParameterSetName = 'Manual')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Template')]
        [ValidateSet('P0D', 'PT0S', 'P180D')]
        [string]$AutoExtendDuration = 'PT0S',

        [Parameter(Mandatory = $false, ParameterSetName = 'Manual')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Template')]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing New-GDAPRelationship"
        
        # Add template processing logic
        if ($PSCmdlet.ParameterSetName -eq 'Template') {
            try {
                $templatePath = Join-Path $PSScriptRoot '..' 'Config' 'accessTemplates.json'
                $templateContent = Get-Content -Path $templatePath -Raw | ConvertFrom-Json
                
                if (-not $templateContent.templates.$UseTemplate) {
                    throw "Template '$UseTemplate' not found in accessTemplates.json"
                }
                
                Write-Verbose "Using template: $UseTemplate"
                $AccessDetails = $templateContent.templates.$UseTemplate.roleAssignments.roleId
            }
            catch {
                throw "Failed to process template: $_"
            }
        }

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

            # Get the operation status
            $operationUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($relationship.id)/operations"
            $operation = Invoke-RestMethod -Uri $operationUri -Headers $graphToken -Method Get

            # Add operation details to output
            return ([PSCustomObject]@{
                RelationshipId = $relationship.id
                DisplayName = $relationship.displayName
                Status = $relationship.status
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
                    RequestedOn = if ($request.createdDateTime) { [DateTime]$request.createdDateTime } else { $null }
                    LastUpdated = if ($request.lastModifiedDateTime) { [DateTime]$request.lastModifiedDateTime } else { $null }
                }
                Operation = if ($operation.value -and $operation.value[0]) {
                    [PSCustomObject]@{
                        Id = $operation.value[0].id
                        Status = $operation.value[0].status
                        Type = $operation.value[0].operationType
                        LastUpdated = if ($operation.value[0].lastModifiedDateTime) { 
                            [DateTime]$operation.value[0].lastModifiedDateTime 
                        } else { 
                            $null 
                        }
                    }
                } else {
                    $null
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