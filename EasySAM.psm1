#Requires -Version 7
$Functions = @(Get-ChildItem -Path $PSScriptRoot\Public\ -Include *.ps1 -Recurse) + @(Get-ChildItem -Path $PSScriptRoot\Private\ -Include *.ps1 -Recurse)
# Import functions.
foreach ($Function in @($Functions)) {
    try {
        Write-Verbose "Importing function $($Function.FullName)"
        . $Function.FullName
    } catch {
        Write-Error -Message "Failed to import function $($Function.FullName): $_"
    }
}

# Initialize script-level variables
$script:SAMConfig = $null