#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $mainScript = Join-Path $projectRoot 'src\Main.ps1'

    if (-not (Test-Path -LiteralPath $mainScript)) {
        throw "Main script not found: $mainScript"
    }

    & $mainScript -ProjectRoot $projectRoot
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
