function Get-WingetCommand {
    [CmdletBinding()]
    param()

    Get-Command winget.exe -ErrorAction SilentlyContinue
}

function Get-WingetStatus {
    [CmdletBinding()]
    param()

    $command = Get-WingetCommand
    if ($null -eq $command) {
        return [PSCustomObject]@{
            IsAvailable = $false
            Version     = ''
            Path        = ''
            Message     = 'WinGet is unavailable. Install or repair Microsoft App Installer from the Microsoft Store.'
        }
    }

    $result = Invoke-ExternalCommand -FilePath $command.Source -Arguments @('--version') -TimeoutSeconds 20
    $version = ($result.StdOut -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
        $details = $result.StdErr.Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "code de sortie $($result.ExitCode)"
        }

        return [PSCustomObject]@{
            IsAvailable = $false
            Version     = ''
            Path        = $command.Source
            Message     = "WinGet was found but did not respond correctly: $details"
        }
    }

    [PSCustomObject]@{
        IsAvailable = $true
        Version     = $version.Trim()
        Path        = $command.Source
        Message     = "WinGet detected $($version.Trim())"
    }
}

function Test-WingetPackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId
    )

    if (-not (Test-WingetPackageId -PackageId $PackageId)) {
        return [PSCustomObject]@{
            Installed = $false
            ExitCode  = 2
            Message   = "Invalid WinGet ID: $PackageId"
            StdOut    = ''
            StdErr    = ''
        }
    }

    $command = Get-WingetCommand
    if ($null -eq $command) {
        return [PSCustomObject]@{
            Installed = $false
            ExitCode  = 9009
            Message   = 'WinGet was not found.'
            StdOut    = ''
            StdErr    = ''
        }
    }

    $arguments = @(
        'list',
        '--id',
        $PackageId,
        '--exact',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    $result = Invoke-ExternalCommand -FilePath $command.Source -Arguments $arguments -TimeoutSeconds 60
    $combinedOutput = (($result.StdOut, $result.StdErr) -join "`n").Trim()
    $installed = ($result.ExitCode -eq 0 -and $combinedOutput -match [regex]::Escape($PackageId))

    [PSCustomObject]@{
        Installed = [bool]$installed
        ExitCode  = $result.ExitCode
        Message   = if ($installed) { 'Installed' } else { 'Not installed' }
        StdOut    = $result.StdOut
        StdErr    = $result.StdErr
    }
}
