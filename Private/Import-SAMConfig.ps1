function Import-SAMConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath "..\Config\existingSam.json")
    )

    try {
        Write-Verbose "Reading SAM configuration from: $Path"
        
        if (-not (Test-Path -Path $Path)) {
            throw "Configuration file not found at: $Path"
        }

        $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
        
        # Validate required properties
        $requiredProps = @('ApplicationId', 'ApplicationSecret', 'TenantId', 'RefreshToken')
        foreach ($prop in $requiredProps) {
            if (-not $config.$prop) {
                throw "Missing required property: $prop"
            }
        }

        # Set the script-level configuration
        $global:SAMConfig = @{
            ApplicationId = $config.ApplicationId
            ApplicationSecret = $config.ApplicationSecret
            TenantId = $config.TenantId
            RefreshToken = $config.RefreshToken
            AzureRefreshToken = $config.AzureRefreshToken
            DisplayName = $config.DisplayName
            CreatedOn = $config.CreatedOn
        }

        Write-Verbose "SAM configuration imported successfully"
        Write-Output "SAM configuration loaded for application: $($config.DisplayName)"
        
        return [PSCustomObject]$global:SAMConfig
    }
    catch {
        Write-Error "Failed to import SAM configuration: $_"
        throw
    }
}