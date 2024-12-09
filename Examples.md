# EasySAM Usage Examples

## 1. Create a New SAM Application

```powershell
# Create new SAM application
$samParams = @{
    DisplayName = "EasySAM-Test"
    TenantId = "your-msp-tenant-id"  # Optional
    ConfigurePreconsent = $true      # Shows admin consent URL
}

$samConfig = Invoke-NewSAM @samParams -Verbose
```

## 2. Consent Using Existing SAM Configuration

### Example 1: Consent for Specific Customers Using SAM Config Object

```powershell
# Define customers
$customers = @(
    [PSCustomObject]@{
        customerId = "customer-tenant-id-1"
        displayName = "Customer 1"
    },
    [PSCustomObject]@{
        customerId = "customer-tenant-id-2"
        displayName = "Customer 2"
    }
)

# Use existing SAM config object
$consentParams = @{
    Customers = $customers
    SAMConfigObject = $samConfig
    UpdateSamPermission = $false  # Set to true to force update existing permissions
}

Invoke-AppConsentFlow @consentParams -Verbose
```

### Example 2: Consent for All Customers Using SAM Config from File

```powershell
# Process all customers using SAM config from file
$consentParams = @{
    AllCustomers = $true
    existingSAM = $true  # Will load from Config/existingSAM.json
}

Invoke-AppConsentFlow @consentParams -Verbose
```

### Example 3: Update Existing SAM Permissions

```powershell
# Update permissions for specific customer
$customer = [PSCustomObject]@{
    customerId = "customer-tenant-id"
    displayName = "Customer Name"
}

$consentParams = @{
    Customers = $customer
    SAMConfigObject = $samConfig
    UpdateSamPermission = $true  # Forces removal and re-consent of the application
}

Invoke-AppConsentFlow @consentParams -Verbose
```

### Example 4: Using Stored SAM Configuration

```powershell
# Store SAM configuration for reuse
$global:SAMConfig = @{
    ApplicationId = "your-app-id"
    ApplicationSecret = "your-app-secret"
    TenantId = "your-msp-tenant-id"
    RefreshToken = "your-refresh-token"
    DisplayName = "Your SAM App Name"
}

# Use stored config for all customers
Invoke-AppConsentFlow -AllCustomers -Verbose
```

### Example 5: Combining Multiple Options

```powershell
# Process multiple customers with specific options
$customers = @(
    [PSCustomObject]@{
        customerId = "customer-tenant-id-1"
        displayName = "Priority Customer 1"
    },
    [PSCustomObject]@{
        customerId = "customer-tenant-id-2"
        displayName = "Priority Customer 2"
    }
)

$consentParams = @{
    Customers = $customers
    SAMConfigObject = $samConfig
    UpdateSamPermission = $true
    redirectUri = "http://localhost:8400"  # Optional custom redirect URI
}

Invoke-AppConsentFlow @consentParams -Verbose
```

## Notes
- Always store sensitive information (ApplicationSecret, RefreshToken) securely
- The SAM application must be pre-consented in your MSP tenant before using with customers
- Use -Verbose parameter for detailed logging during execution
- The UpdateSamPermission switch is useful when permissions need to be updated
- AllCustomers switch will automatically retrieve all customers from Partner Center