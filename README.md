# EasySAM Module (Still in development)

## Overview
The EasySAM module provides a set of PowerShell scripts designed to simplify the management of Entra application permissions and consent processes specifically for the Secure Application Model (SAM) used in Granular Delegated Admin Privileges (GDAP). This module allows users to automate the creation and management of SAM applications, making it easier to handle permissions for various Azure services in a secure manner.

## Features
- **Application Consent Flow**: Automate the consent process for AAD applications under the Secure Application Model.
- **Permission Management**: Easily manage application permissions and roles in a granular manner.

## Roadmap (when i find the time :D)
- **GDAP Contract mapping to Entra Groups**: Map GDAP contracts to Entra groups to manage permissions.
- **Remove Graph Module dependency**: Remove the dependency on the Graph module and convert to native API calls.

## Installation
To install the EasySAM module, clone the repository and import the module into your PowerShell session.

## Example Usage
To use the EasySAM module, you can call the provided functions to manage application permissions and consent flows as per your requirements. 

See Example below for creating a new SAM application.

```powershell
$samParams = @{
    DisplayName         = "EasySAM-Test-3"
    TenantId            = "<Your-MSP-Tenant-ID>" # Optional
    ConfigurePreconsent = $true # Optional, this will try to open a browser to consent the application.
    ExportConfig        = $false # Optional, this will export the config to the existingSAM.json file in the Config folder.
}

# Execute the function
$result = Invoke-NewSAM @samParams -Verbose
#Result will contain the new SAM details like the refresh token, client id, etc.
```

Consent the new created application in a remote customer tenant, keep in mind that you do not need to have a existingSAM.json file or specify the -SAMConfig parameter. When created a new SAM application in the current powershell session the module will automatically load the new config from the global:SAMConfig variable, which is set when the new SAM application is created.

```powershell

$customers = [PSCustomObject]@{
    customerId = "8821ff3c-8b0d-4dd4-8813-39fca432cd19"
    displayName = "Skrok Lab Tenant 2"
}

Invoke-AppConsentFlow -Customers $customers -Verbose

#Or consent to all customers in Partner Center

Invoke-AppConsentFlow -AllCustomers -Verbose

```

For more examples see the Examples.md file. 
Keep in mind that for you to able to use the SAM application you need to have the correct GDAP roles assigned to the service account.
For setting this up you can use Microsoft Lighthouse check this link for more information: https://learn.microsoft.com/en-us/microsoft-365/lighthouse/m365-lighthouse-setup-gdap?view=o365-worldwide
## Contributing
Contributions to the EasySAM module are welcome. Please submit a pull request or open an issue for any enhancements or bug fixes.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

