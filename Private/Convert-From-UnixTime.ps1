    # Helper function to convert Unix timestamp to datetime
    function ConvertFrom-UnixTime {
        param ([Parameter(Mandatory = $true)][int64]$UnixTime)
        return [DateTimeOffset]::FromUnixTimeSeconds($UnixTime).LocalDateTime
    }