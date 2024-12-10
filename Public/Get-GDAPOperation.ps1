function Get-GDAPOperation {
    [CmdletBinding(DefaultParameterSetName = 'Specific')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Specific')]
        [string]$RelationshipId,

        [Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
        [string]$OperationId,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$SAMConfigObject
    )

    begin {
        Write-Verbose "Initializing Get-GDAPOperation"
        
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
            throw "SAM configuration not found. Please provide configuration." 
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
    }

    process {
        try {
            if ($All) {
                # Get all GDAP relationships first
                Write-Verbose "Retrieving all GDAP relationships"
                $relationshipsUri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships"
                $relationships = (Invoke-RestMethod -Uri $relationshipsUri -Headers $graphToken -Method Get).value

                # Create a list to store all operations
                $allOperations = [System.Collections.Generic.List[PSCustomObject]]::new()

                # Get operations for each relationship
                foreach ($relationship in $relationships) {
                    Write-Verbose "Retrieving operations for relationship: $($relationship.id)"
                    $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($relationship.id)/operations"
                    
                    try {
                        $operations = (Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get).value
                        
                        foreach ($operation in $operations) {
                            $allOperations.Add([PSCustomObject]@{
                                RelationshipId = $relationship.id
                                RelationshipName = $relationship.displayName
                                CustomerTenantId = $relationship.customer.tenantId
                                CustomerName = $relationship.customer.displayName
                                OperationId = $operation.id
                                Status = $operation.status
                                Type = $operation.operationType
                                CreatedDateTime = [DateTime]$operation.createdDateTime
                                LastModifiedDateTime = [DateTime]$operation.lastModifiedDateTime
                                Error = if ($operation.error) {
                                    [PSCustomObject]@{
                                        Code = $operation.error.code
                                        Message = $operation.error.message
                                    }
                                } else { $null }
                            })
                        }
                    }
                    catch {
                        Write-Warning "Failed to retrieve operations for relationship $($relationship.id): $_"
                        continue
                    }
                }

                return $allOperations
            }
            elseif ($OperationId) {
                # Get specific operation
                $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/operations/$OperationId"
                $operation = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get
                
                return [PSCustomObject]@{
                    Id = $operation.id
                    Status = $operation.status
                    Type = $operation.operationType
                    CreatedDateTime = [DateTime]$operation.createdDateTime
                    LastModifiedDateTime = [DateTime]$operation.lastModifiedDateTime
                    Error = if ($operation.error) {
                        [PSCustomObject]@{
                            Code = $operation.error.code
                            Message = $operation.error.message
                        }
                    } else { $null }
                }
            }
            else {
                # List all operations for specific relationship
                $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$RelationshipId/operations"
                $operations = Invoke-RestMethod -Uri $uri -Headers $graphToken -Method Get
                
                return $operations.value | ForEach-Object {
                    [PSCustomObject]@{
                        Id = $_.id
                        Status = $_.status
                        Type = $_.operationType
                        CreatedDateTime = [DateTime]$_.createdDateTime
                        LastModifiedDateTime = [DateTime]$_.lastModifiedDateTime
                        Error = if ($_.error) {
                            [PSCustomObject]@{
                                Code = $_.error.code
                                Message = $_.error.message
                            }
                        } else { $null }
                    }
                }
            }
        }
        catch {
            Write-Error "Error retrieving GDAP operations: $_"
            throw
        }
    }
}