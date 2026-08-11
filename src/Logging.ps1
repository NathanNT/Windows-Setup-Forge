function Initialize-Logger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $fileName = 'setup-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd-HHmmss')
    $path = Join-Path $LogDirectory $fileName
    New-Item -ItemType File -Path $path -Force | Out-Null

    [PSCustomObject]@{
        Path      = $path
        Directory = $LogDirectory
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Logger,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level.ToUpperInvariant(), $Message

    try {
        Add-Content -LiteralPath $Logger.Path -Value $line -Encoding UTF8
    }
    catch {
        Write-Warning "Unable to write to the log file: $($_.Exception.Message)"
    }

    $line
}
