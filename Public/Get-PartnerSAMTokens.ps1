function Get-PartnerSAMTokens {
    <#
    .SYNOPSIS
    Gets an authorization token from Microsoft Partner Center using OAuth 2.0 authorization code flow.

    .DESCRIPTION
    This function initiates an OAuth 2.0 authorization code flow to obtain an access token for Microsoft Partner Center.
    It opens a browser window for user authentication, starts a local HTTP listener to receive the callback,
    and exchanges the authorization code for an access token.

    .PARAMETER TenantId
    The Microsoft Partner Center tenant ID (MSP Tenant ID)

    .PARAMETER ApplicationId
    The application ID (client ID) of the SAM application registered in Entra ID

    .PARAMETER ApplicationSecret
    The client secret of the SAM application

    .PARAMETER RedirectUri
    The redirect URI configured for the application. Defaults to 'http://localhost:8400'

    .PARAMETER Scope
    The requested scope for the access token. Defaults to 'https://api.partnercenter.microsoft.com/.default'

    .PARAMETER TimeoutSeconds
    Timeout in seconds for the authentication process. Defaults to 300 seconds (5 minutes)

    .EXAMPLE
    $params = @{
        TenantId = "12345678-1234-1234-1234-123456789012"
        ApplicationId = "87654321-4321-4321-4321-210987654321"
        ApplicationSecret = "your-secret-here"
    }
    $token = Get-PartnerSAMTokens @params

    .NOTES
    Requires System.Web assembly for URL parsing.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationSecret,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RedirectUri = 'http://localhost:8400',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Scope = 'https://api.partnercenter.microsoft.com/.default',

        [Parameter(Mandatory = $false)]
        [ValidateRange(60, 900)]
        [int]$TimeoutSeconds = 300
    )

    begin {
        Write-Verbose "Starting OAuth flow for tenant: $TenantId"
        
        # Add required assembly
        try {
            Add-Type -AssemblyName System.Web
        }
        catch {
            throw "Failed to load System.Web assembly: $_"
        }

        # Initialize variables
        $listener = $null
        $context = $null
        $port = ([System.Uri]$RedirectUri).Port
        $listenerPrefix = "http://localhost:$port/"

        # Helper function to send browser response
        function Send-BrowserResponse {
            param (
                [Parameter(Mandatory = $true)]
                $Context,
                
                [Parameter(Mandatory = $true)]
                [string]$Message,
                
                [Parameter(Mandatory = $false)]
                [System.Net.HttpStatusCode]$StatusCode = [System.Net.HttpStatusCode]::OK
            )
            
            try {
                $response = $Context.Response
                $response.StatusCode = [int]$StatusCode
                $responseHtml = "<html><body><h2>$Message</h2></body></html>"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseHtml)
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                $response.Close()
            }
            catch {
                Write-Verbose "Failed to send browser response: $_"
            }
        }

        # Helper function to exchange code for token
        function Get-TokenFromCode {
            param (
                [Parameter(Mandatory = $true)]
                [string]$AuthCode
            )
            
            try {
                $body = "grant_type=authorization_code&client_id=$ApplicationId&client_secret=$ApplicationSecret&code=$AuthCode&redirect_uri=$RedirectUri&scope=$Scope"
                $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
                $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/token"
                
                $response = Invoke-RestMethod -Method POST -Uri $tokenEndpoint -Body $body -Headers $headers
                return $response
            }
            catch {
                throw "Failed to exchange code for token: $_"
            }
        }
    }

    process {
        try {
            # Create and start HTTP listener
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add($listenerPrefix)
            $listener.Start()
            Write-Verbose "Started HTTP listener on $listenerPrefix"

            # Construct and open authorization URL
            $authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?" + 
                      "client_id=$ApplicationId&" +
                      "response_type=code&" +
                      "redirect_uri=$([System.Web.HttpUtility]::UrlEncode($RedirectUri))&" +
                      "scope=$([System.Web.HttpUtility]::UrlEncode($Scope))"

            Start-Process $authUrl
            Write-Output "Waiting for authentication response... (Press Ctrl+C to cancel)"

            # Wait for the callback
            $startTime = Get-Date
            $result = $listener.BeginGetContext($null, $null)
            $waitHandle = $result.AsyncWaitHandle

            while ($true) {
                try {
                    if ($waitHandle.WaitOne(1000)) {
                        $context = $listener.EndGetContext($result)
                        if ($null -ne $context) {
                            $requestUrl = $context.Request.Url
                            $queryParams = [System.Web.HttpUtility]::ParseQueryString($requestUrl.Query)
                            
                            # Check for HTTP errors first
                            if ($context.Request.HttpMethod -eq 'GET' -and $context.Response.StatusCode -ge 400) {
                                Send-BrowserResponse -Context $context -Message "HTTP Error: $($context.Response.StatusCode) - $($context.Response.StatusDescription)" -StatusCode 400
                                throw "HTTP Error: $($context.Response.StatusCode) - $($context.Response.StatusDescription)"
                            }

                            # Check for empty or malformed requests
                            if ($null -eq $requestUrl -or [string]::IsNullOrEmpty($requestUrl.Query)) {
                                Send-BrowserResponse -Context $context -Message "Invalid Request" -StatusCode 400
                                throw "Invalid or empty request received"
                            }
                            
                            # Check for authorization code
                            $code = $queryParams["code"]
                            if ($code -and $code.Length -gt 100) {
                                Write-Verbose "Successfully received authorization code"
                                Send-BrowserResponse -Context $context -Message "Authorization successful! You can close this window."
                                return Get-TokenFromCode -AuthCode $code
                            }
                            
                            # Check for various error conditions
                            $authError = $queryParams["error"]
                            $errorDescription = $queryParams["error_description"]
                            if ($authError -or $errorDescription) {
                                Send-BrowserResponse -Context $context -Message "Authentication Error: $errorDescription" -StatusCode 400
                                throw "Authentication error: $authError - $errorDescription"
                            }
                        }
                    }

                    $elapsedSeconds = ((Get-Date) - $startTime).TotalSeconds
                    if ($elapsedSeconds -ge $TimeoutSeconds) {
                        throw "Authentication timed out after $TimeoutSeconds seconds"
                    }

                    Write-Output "Waiting for response... ($([math]::Round($elapsedSeconds))/$TimeoutSeconds seconds)"
                }
                catch {
                    Write-Error "Authentication process failed: $_"
                    if ($null -ne $context -and $null -ne $context.Response) {
                        Send-BrowserResponse -Context $context -Message "Authentication failed: $($_.Exception.Message)" -StatusCode 400
                    }
                    throw
                }
            }
        }
        catch {
            Write-Error "Authorization failed: $_"
            throw
        }
        finally {
            if ($null -ne $listener -and $listener.IsListening) {
                $listener.Stop()
                $listener.Close()
                Write-Verbose "HTTP listener stopped and closed"
            }
        }
    }

    end {
        Write-Verbose "OAuth flow completed"
    }
}