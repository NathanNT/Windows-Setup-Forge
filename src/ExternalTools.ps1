#requires -Version 5.1

function Get-ExternalToolsRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectRoot
    )

    Join-Path $ProjectRoot 'external'
}

function Write-ExternalToolLog {
    param(
        [Parameter()]
        [scriptblock]$LogCallback,

        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($null -ne $LogCallback) {
        & $LogCallback $Level $Message
    }
}

function Get-CurrentPowerShellExecutable {
    [CmdletBinding()]
    param()

    try {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        if ($null -ne $process -and -not [string]::IsNullOrWhiteSpace($process.ExecutablePath) -and (Test-Path -LiteralPath $process.ExecutablePath)) {
            return $process.ExecutablePath
        }
    }
    catch {
        # Fall back to the executable in PSHOME below.
    }

    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $candidate = Join-Path $PSHOME $name
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    'powershell.exe'
}

function Save-GitHubRepositoryArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipUri,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationRoot,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    $uri = [Uri]$ZipUri
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com', 'codeload.github.com')) {
        throw "External tool archive must use an official HTTPS GitHub URL: $ZipUri"
    }

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        [void](New-Item -Path $DestinationRoot -ItemType Directory -Force)
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $toolRoot = Join-Path $DestinationRoot $RepositoryName
    $downloadRoot = Join-Path $toolRoot $timestamp
    $archivePath = Join-Path $downloadRoot "$RepositoryName.zip"
    $extractPath = Join-Path $downloadRoot 'source'

    [void](New-Item -Path $downloadRoot -ItemType Directory -Force)

    Write-ExternalToolLog -LogCallback $LogCallback -Level 'INFO' -Message "Downloading $RepositoryName from $ZipUri"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Older hosts may not expose the same enum values; Invoke-WebRequest will use its default.
    }

    Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $archivePath -UseBasicParsing -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $archivePath)) {
        throw "Download failed: archive was not created at $archivePath"
    }

    Write-ExternalToolLog -LogCallback $LogCallback -Level 'INFO' -Message "Extracting $RepositoryName to $extractPath"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

    [PSCustomObject]@{
        RepositoryName = $RepositoryName
        ArchivePath    = $archivePath
        ExtractPath     = $extractPath
        DownloadRoot    = $downloadRoot
    }
}

function Invoke-Win11Debloat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectRoot,

        [Parameter()]
        [bool]$RunAsAdministrator = $true,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    $externalRoot = Get-ExternalToolsRoot -ProjectRoot $ProjectRoot
    $archive = Save-GitHubRepositoryArchive `
        -RepositoryName 'Win11Debloat' `
        -ZipUri 'https://github.com/Raphire/Win11Debloat/archive/refs/heads/master.zip' `
        -DestinationRoot $externalRoot `
        -LogCallback $LogCallback

    $scriptPath = Get-ChildItem -LiteralPath $archive.ExtractPath -Recurse -Filter 'Win11Debloat.ps1' -File |
        Select-Object -First 1 -ExpandProperty FullName

    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        throw "Win11Debloat.ps1 was not found in the downloaded archive."
    }

    $powerShellPath = Get-CurrentPowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$scriptPath`""
    )

    Write-ExternalToolLog -LogCallback $LogCallback -Level 'INFO' -Message "Launching Win11Debloat script: $scriptPath"

    $startParameters = @{
        FilePath     = $powerShellPath
        ArgumentList = $arguments
        Wait         = $true
        PassThru     = $true
    }

    if ($RunAsAdministrator) {
        $startParameters.Verb = 'RunAs'
        Write-ExternalToolLog -LogCallback $LogCallback -Level 'INFO' -Message 'Win11Debloat will request administrator privileges.'
    }

    $process = Start-Process @startParameters
    $exitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    $success = ($null -eq $exitCode -or $exitCode -eq 0)
    $message = if ($success) {
        'Win11Debloat completed or was closed without reporting an error.'
    }
    else {
        "Win11Debloat exited with code $exitCode."
    }

    Write-ExternalToolLog -LogCallback $LogCallback -Level $(if ($success) { 'SUCCESS' } else { 'ERROR' }) -Message $message

    [PSCustomObject]@{
        Success      = [bool]$success
        ExitCode     = $exitCode
        Message      = $message
        ScriptPath   = $scriptPath
        DownloadRoot = $archive.DownloadRoot
    }
}
