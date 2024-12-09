function Get-PermissionId {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceAppId,

        [Parameter(Mandatory = $true)]
        [string]$PermissionName
    )

    # Retrieve the service principal for the resource
    $sp = Get-MgServicePrincipal -Filter "appId eq '$ResourceAppId'" | Select-Object -First 1

    if (-not $sp) {
        Throw "Service Principal with AppId $ResourceAppId not found."
    }

    # Check for delegated permissions (OAuth2PermissionScopes)
    $delegatedPermission = $sp.Oauth2PermissionScopes | Where-Object { $_.Value -eq $PermissionName }

    if ($delegatedPermission) {
        return @{
            Id   = $delegatedPermission.Id
            Type = "Scope"
        }
    }

    # Check for application permissions (AppRoles)
    $applicationPermission = $sp.AppRoles | Where-Object { $_.Value -eq $PermissionName }

    if ($applicationPermission) {
        return @{
            Id   = $applicationPermission.Id
            Type = "Role"
        }
    }

    Throw "Permission '$PermissionName' not found in Service Principal $ResourceAppId."
}
