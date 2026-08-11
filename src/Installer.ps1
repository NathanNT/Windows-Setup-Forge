function Test-WingetAlreadyInstalledOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $Text -match '(?i)(already installed|déjà installé|deja installe|no applicable update|no available upgrade|aucune mise à jour|aucune mise a jour|aucune mise à niveau|aucune mise a niveau)'
}

function Get-WingetFailureMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Result
    )

    $text = (($Result.StdOut, $Result.StdErr) -join "`n")

    if ($Result.TimedOut) {
        return 'The operation timed out.'
    }

    if ($text -match '(?i)(no package found|package not found|aucun package|introuvable|not found)') {
        return 'Package not found in the configured WinGet sources.'
    }

    if ($text -match '(?i)(network|internet|connexion|connection|source|0x8a15000f|0x8a150044)') {
        return 'WinGet reported a source or Internet connection problem.'
    }

    if ($text -match '(?i)(administrator|admin|elevation|elevated|élévation|elevation required|access is denied|accès refusé)') {
        return 'The installation appears to require administrator privileges.'
    }

    if ($text -match '(?i)(cancelled|canceled|annulé|annule|aborted|interrompu)') {
        return 'The installation was canceled or interrupted.'
    }

    'WinGet returned exit code {0}.' -f $Result.ExitCode
}

function Write-InstallerLog {
    [CmdletBinding()]
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

function Write-CommandOutputToLog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock]$LogCallback,

        [Parameter()]
        [AllowEmptyString()]
        [string]$StdOut,

        [Parameter()]
        [AllowEmptyString()]
        [string]$StdErr
    )

    foreach ($line in (($StdOut -split "(`r`n|`n|`r)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message $line.Trim()
    }

    foreach ($line in (($StdErr -split "(`r`n|`n|`r)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Write-InstallerLog -LogCallback $LogCallback -Level 'WARN' -Message $line.Trim()
    }
}

function Invoke-VerifyCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VerifyCommand,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    Update-ProcessPath | Out-Null
    $tokens = @(Split-CommandLine -CommandLine $VerifyCommand)

    if ($tokens.Count -eq 0) {
        return [PSCustomObject]@{
            Status  = 'Skipped'
            Success = $null
            Message = 'No verification command defined.'
        }
    }

    $executable = $tokens[0]
    $command = Get-Command $executable -ErrorAction SilentlyContinue

    if ($null -eq $command) {
        $message = "Optional verification unavailable for ${Name}: '$executable' is not available in this process PATH."
        Write-InstallerLog -LogCallback $LogCallback -Level 'WARN' -Message $message
        return [PSCustomObject]@{
            Status  = 'Unavailable'
            Success = $null
            Message = $message
        }
    }

    $arguments = @()
    if ($tokens.Count -gt 1) {
        $arguments = @($tokens[1..($tokens.Count - 1)])
    }

    Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message "Verification: $VerifyCommand"
    $result = Invoke-ExternalCommand -FilePath $command.Source -Arguments $arguments -TimeoutSeconds 30
    Write-CommandOutputToLog -LogCallback $LogCallback -StdOut $result.StdOut -StdErr $result.StdErr

    if ($result.ExitCode -eq 0) {
        return [PSCustomObject]@{
            Status  = 'Passed'
            Success = $true
            Message = 'Verification succeeded.'
        }
    }

    [PSCustomObject]@{
        Status  = 'Failed'
        Success = $false
        Message = "Optional verification returned exit code $($result.ExitCode)."
    }
}

function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Name = $Id,

        [Parameter()]
        [AllowEmptyString()]
        [string]$VerifyCommand = '',

        [Parameter()]
        [bool]$ReinstallInstalled = $false,

        [Parameter()]
        [bool]$RequiresAdmin = $false,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    if (-not (Test-WingetPackageId -PackageId $Id)) {
        $message = "ID WinGet invalide : $Id"
        Write-InstallerLog -LogCallback $LogCallback -Level 'ERROR' -Message $message
        return [PSCustomObject]@{
            Name             = $Name
            Id               = $Id
            Success          = $false
            AlreadyInstalled = $false
            Skipped          = $false
            ExitCode         = 2
            Message          = $message
            Verification     = $null
            StdOut           = ''
            StdErr           = ''
        }
    }

    $command = Get-WingetCommand
    if ($null -eq $command) {
        $message = 'WinGet was not found. Microsoft App Installer must be available.'
        Write-InstallerLog -LogCallback $LogCallback -Level 'ERROR' -Message $message
        return [PSCustomObject]@{
            Name             = $Name
            Id               = $Id
            Success          = $false
            AlreadyInstalled = $false
            Skipped          = $false
            ExitCode         = 9009
            Message          = $message
            Verification     = $null
            StdOut           = ''
            StdErr           = ''
        }
    }

    if (-not $ReinstallInstalled) {
        $installedState = Test-WingetPackageInstalled -PackageId $Id
        if ($installedState.Installed) {
            $message = "$Name is already installed."
            Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message $message
            return [PSCustomObject]@{
                Name             = $Name
                Id               = $Id
                Success          = $true
                AlreadyInstalled = $true
                Skipped          = $false
                ExitCode         = 0
                Message          = $message
                Verification     = $null
                StdOut           = $installedState.StdOut
                StdErr           = $installedState.StdErr
            }
        }
    }

    if ($RequiresAdmin -and -not (Test-IsAdministrator)) {
        Write-InstallerLog -LogCallback $LogCallback -Level 'WARN' -Message "$Name may require administrator privileges."
    }

    $arguments = @(
        'install',
        '--id',
        $Id,
        '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--source',
        'winget'
    )

    Write-InstallerLog -LogCallback $LogCallback -Level 'INSTALL' -Message "Installing $Id"
    Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message ("Command: winget {0}" -f (Join-ProcessArguments -Arguments $arguments))

    $result = Invoke-ExternalCommand -FilePath $command.Source -Arguments $arguments -TimeoutSeconds 0
    Write-CommandOutputToLog -LogCallback $LogCallback -StdOut $result.StdOut -StdErr $result.StdErr

    $combinedOutput = (($result.StdOut, $result.StdErr) -join "`n")
    if (Test-WingetAlreadyInstalledOutput -Text $combinedOutput) {
        $message = "$Name is already installed."
        Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message $message
        return [PSCustomObject]@{
            Name             = $Name
            Id               = $Id
            Success          = $true
            AlreadyInstalled = $true
            Skipped          = $false
            ExitCode         = $result.ExitCode
            Message          = $message
            Verification     = $null
            StdOut           = $result.StdOut
            StdErr           = $result.StdErr
        }
    }

    if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
        $verification = $null
        if (-not [string]::IsNullOrWhiteSpace($VerifyCommand)) {
            $verification = Invoke-VerifyCommand -Name $Name -VerifyCommand $VerifyCommand -LogCallback $LogCallback
        }

        $message = if ($result.ExitCode -eq 3010) {
            "$Name installed successfully. A restart may be required."
        }
        else {
            "$Name installed successfully."
        }

        Write-InstallerLog -LogCallback $LogCallback -Level 'SUCCESS' -Message $message

        return [PSCustomObject]@{
            Name             = $Name
            Id               = $Id
            Success          = $true
            AlreadyInstalled = $false
            Skipped          = $false
            ExitCode         = $result.ExitCode
            Message          = $message
            Verification     = $verification
            StdOut           = $result.StdOut
            StdErr           = $result.StdErr
        }
    }

    $failureMessage = Get-WingetFailureMessage -Result $result
    Write-InstallerLog -LogCallback $LogCallback -Level 'ERROR' -Message "Failed to install ${Name}: $failureMessage"

    [PSCustomObject]@{
        Name             = $Name
        Id               = $Id
        Success          = $false
        AlreadyInstalled = $false
        Skipped          = $false
        ExitCode         = $result.ExitCode
        Message          = $failureMessage
        Verification     = $null
        StdOut           = $result.StdOut
        StdErr           = $result.StdErr
    }
}

function Invoke-WingetUpgradeAll {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock]$LogCallback
    )

    $command = Get-WingetCommand
    if ($null -eq $command) {
        $message = 'WinGet was not found. Global update is unavailable.'
        Write-InstallerLog -LogCallback $LogCallback -Level 'ERROR' -Message $message
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = 9009
            Message  = $message
            StdOut   = ''
            StdErr   = ''
        }
    }

    $arguments = @(
        'upgrade',
        '--all',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--source',
        'winget'
    )

    Write-InstallerLog -LogCallback $LogCallback -Level 'INSTALL' -Message 'Updating all applications through WinGet.'
    Write-InstallerLog -LogCallback $LogCallback -Level 'INFO' -Message ("Command: winget {0}" -f (Join-ProcessArguments -Arguments $arguments))

    $result = Invoke-ExternalCommand -FilePath $command.Source -Arguments $arguments -TimeoutSeconds 0
    Write-CommandOutputToLog -LogCallback $LogCallback -StdOut $result.StdOut -StdErr $result.StdErr

    if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
        $message = if ($result.ExitCode -eq 3010) {
            'Update completed. A restart may be required.'
        }
        else {
            'Global update completed.'
        }

        Write-InstallerLog -LogCallback $LogCallback -Level 'SUCCESS' -Message $message
        return [PSCustomObject]@{
            Success  = $true
            ExitCode = $result.ExitCode
            Message  = $message
            StdOut   = $result.StdOut
            StdErr   = $result.StdErr
        }
    }

    $failureMessage = Get-WingetFailureMessage -Result $result
    Write-InstallerLog -LogCallback $LogCallback -Level 'ERROR' -Message "Global update failed: $failureMessage"

    [PSCustomObject]@{
        Success  = $false
        ExitCode = $result.ExitCode
        Message  = $failureMessage
        StdOut   = $result.StdOut
        StdErr   = $result.StdErr
    }
}
