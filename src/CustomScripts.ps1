#requires -Version 5.1

function Get-CustomScriptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectRoot
    )

    Join-Path $ProjectRoot 'custom\CustomScript.ps1'
}

function Write-CustomScriptLog {
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

function Assert-CustomScriptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath
    )

    $customRoot = Join-Path $ProjectRoot 'custom'
    if (-not (Test-Path -LiteralPath $customRoot)) {
        [void](New-Item -Path $customRoot -ItemType Directory -Force)
    }

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        [void](New-Item -Path $ScriptPath -ItemType File -Force)
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $customRoot).Path.TrimEnd('\')
    $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path

    if (-not $resolvedScript.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Custom script must stay inside the project custom folder: $resolvedRoot"
    }

    $resolvedScript
}

function Invoke-CustomScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectRoot,

        [Parameter()]
        [bool]$RunAsAdministrator = $false,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    $scriptPath = Get-CustomScriptPath -ProjectRoot $ProjectRoot
    $scriptPath = Assert-CustomScriptPath -ProjectRoot $ProjectRoot -ScriptPath $scriptPath

    $content = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-CustomScriptLog -LogCallback $LogCallback -Level 'WARN' -Message 'Custom script is empty.'
    }

    $powerShellPath = if (Get-Command Get-CurrentPowerShellExecutable -ErrorAction SilentlyContinue) {
        Get-CurrentPowerShellExecutable
    }
    else {
        'powershell.exe'
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$scriptPath`""
    )

    Write-CustomScriptLog -LogCallback $LogCallback -Level 'INFO' -Message "Running custom script: $scriptPath"

    $startParameters = @{
        FilePath     = $powerShellPath
        ArgumentList = $arguments
        Wait         = $true
        PassThru     = $true
    }

    if ($RunAsAdministrator) {
        $startParameters.Verb = 'RunAs'
        Write-CustomScriptLog -LogCallback $LogCallback -Level 'INFO' -Message 'Custom script will request administrator privileges.'
    }

    $process = Start-Process @startParameters
    $exitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    $success = ($null -eq $exitCode -or $exitCode -eq 0)
    $message = if ($success) {
        'Custom script completed successfully.'
    }
    else {
        "Custom script exited with code $exitCode."
    }

    Write-CustomScriptLog -LogCallback $LogCallback -Level $(if ($success) { 'SUCCESS' } else { 'ERROR' }) -Message $message

    [PSCustomObject]@{
        Success    = [bool]$success
        ExitCode   = $exitCode
        Message    = $message
        ScriptPath = $scriptPath
    }
}
