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

function New-CustomScriptRunnerContent {
    [CmdletBinding()]
    param()

@'
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ScriptPath,

    [Parameter(Mandatory)]
    [string]$OutputLog
)

$ErrorActionPreference = 'Continue'
$exitCode = 0

try {
    $logDirectory = Split-Path -Parent $OutputLog
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        [void](New-Item -Path $logDirectory -ItemType Directory -Force)
    }

    "==== SetupForge custom script started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Force
    "Script: $ScriptPath" | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append
    "" | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append

    & $ScriptPath *>&1 | ForEach-Object {
        $text = ($_ | Out-String).TrimEnd()
        if (-not [string]::IsNullOrEmpty($text)) {
            $text | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append
            Write-Output $text
        }
    }

    if ($global:LASTEXITCODE -is [int]) {
        $exitCode = $global:LASTEXITCODE
    }
}
catch {
    $exitCode = 1
    $message = "ERROR: $($_.Exception.Message)"
    $message | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append
    Write-Output $message
}
finally {
    "" | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append
    "==== SetupForge custom script finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ExitCode: $exitCode ====" | Out-File -LiteralPath $OutputLog -Encoding UTF8 -Append
}

exit $exitCode
'@
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

    $logDirectory = Join-Path $ProjectRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        [void](New-Item -Path $logDirectory -ItemType Directory -Force)
    }

    $outputLog = Join-Path $logDirectory ('custom-script-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    $runnerPath = Join-Path ([System.IO.Path]::GetTempPath()) ('SetupForge-CustomScript-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
    $encoding = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($runnerPath, (New-CustomScriptRunnerContent), $encoding)

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$runnerPath`"",
        '-ScriptPath',
        "`"$scriptPath`"",
        '-OutputLog',
        "`"$outputLog`""
    )

    Write-CustomScriptLog -LogCallback $LogCallback -Level 'INFO' -Message "Running custom script: $scriptPath"
    Write-CustomScriptLog -LogCallback $LogCallback -Level 'INFO' -Message "Custom script output log: $outputLog"

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

    try {
        $process = Start-Process @startParameters
        $exitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    }
    finally {
        if (Test-Path -LiteralPath $runnerPath) {
            Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $outputLog) {
        $outputLines = @(Get-Content -LiteralPath $outputLog -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $outputLines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-CustomScriptLog -LogCallback $LogCallback -Level 'CUSTOM' -Message $line
            }
        }
    }
    else {
        Write-CustomScriptLog -LogCallback $LogCallback -Level 'WARN' -Message 'Custom script output log was not created.'
    }

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
        OutputLog  = $outputLog
    }
}
