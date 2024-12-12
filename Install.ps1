# Define the GitHub repository URL
$repoUrl = "https://github.com/freezscholte/EasySAM"
$zipUrl = "$repoUrl/archive/refs/heads/main.zip"

# Current directory where the script is run
$currentDir = Get-Location

# Path for the downloaded ZIP file
$zipPath = Join-Path $currentDir "EasySAM.zip"

# Destination folder for extraction
$extractPath = Join-Path $currentDir "EasySAM"
$tempExtractPath = Join-Path $currentDir "EasySAM-main"

try {
    Write-Output "Downloading repository from $zipUrl..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

    Write-Output "Download complete. Extracting contents..."
    Expand-Archive -Path $zipPath -DestinationPath $currentDir -Force

    # Move contents from EasySAM-main to EasySAM
    if (Test-Path $tempExtractPath) {
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force
        }
        Rename-Item -Path $tempExtractPath -NewName "EasySAM" -Force
        Write-Output "Extraction complete. The repository is now available in the '$extractPath' folder."
    } else {
        throw "Expected folder '$tempExtractPath' not found after extraction"
    }
}
catch {
    Write-Output "An error occurred: $($_.Exception.Message)"
    return
}

try {
    # Clean up: Remove the ZIP file
    Remove-Item $zipPath -Force
    Write-Output "Temporary ZIP file removed."

    # Import the module
    $moduleFile = Join-Path $extractPath "EasySAM.psm1"
    Import-Module $moduleFile -Force -ErrorAction Stop
    Write-Output "EasySAM module successfully imported."
}
catch {
    Write-Output "Failed to import module: $($_.Exception.Message)"
}