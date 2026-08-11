#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

$script:ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$script:SourceRoot = $PSScriptRoot
$script:AppCatalogPath = Join-Path $script:ProjectRoot 'apps.json'
$script:LogDirectory = Join-Path $script:ProjectRoot 'logs'
$script:EntryPoint = Join-Path $script:ProjectRoot 'Start-Setup.ps1'

. (Join-Path $script:SourceRoot 'Environment.ps1')
. (Join-Path $script:SourceRoot 'Models.ps1')
. (Join-Path $script:SourceRoot 'Logging.ps1')
. (Join-Path $script:SourceRoot 'Detection.ps1')
. (Join-Path $script:SourceRoot 'Installer.ps1')
. (Join-Path $script:SourceRoot 'ExternalTools.ps1')
. (Join-Path $script:SourceRoot 'CustomScripts.ps1')
. (Join-Path $script:SourceRoot 'VmDeployment.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Logger = Initialize-Logger -LogDirectory $script:LogDirectory
$script:Apps = @()
$script:AppMap = @{}
$script:DisplayedApps = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:EventQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Busy = $false
$script:BusyMode = ''
$script:WorkerPowerShell = $null
$script:WorkerHandle = $null
$script:WorkerCompletionSeen = $true
$script:WingetAvailable = $false
$script:CatalogLoaded = $false
$script:IsAdministrator = Test-IsAdministrator

function Get-NamedControl {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $control = $script:Window.FindName($Name)
    if ($null -eq $control) {
        throw "XAML control not found: $Name"
    }
    $control
}

function Add-UiLog {
    param(
        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $line = Write-Log -Logger $script:Logger -Level $Level -Message $Message
    $script:LogBox.AppendText($line + [Environment]::NewLine)
    $script:LogBox.ScrollToEnd()
}

function Set-AppControlsEnabled {
    param(
        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $canUseWinget = ($Enabled -and $script:WingetAvailable)
    $script:VerifyButton.IsEnabled = $canUseWinget
    $script:UpgradeButton.IsEnabled = $canUseWinget
    $script:InstallButton.IsEnabled = $canUseWinget
    $script:Win11DebloatButton.IsEnabled = $Enabled
    $script:ActivationSettingsButton.IsEnabled = $Enabled
    $script:CustomScriptButton.IsEnabled = $Enabled
    $script:RefreshVmStatusButton.IsEnabled = $Enabled
    $script:InstallVmwareToolsButton.IsEnabled = $Enabled
    $script:InstallVirtualBoxToolsButton.IsEnabled = $Enabled
    $script:EnableRemoteDesktopButton.IsEnabled = $Enabled
    $script:DisableStickyKeysButton.IsEnabled = $Enabled
    $script:SelectAllButton.IsEnabled = $Enabled
    $script:ClearSelectionButton.IsEnabled = $Enabled
    $script:RecommendedButton.IsEnabled = $Enabled
    $script:ReinstallInstalledCheck.IsEnabled = $Enabled
    $script:AppGrid.IsEnabled = $Enabled
    $script:CategoryList.IsEnabled = $Enabled
    $script:SearchBox.IsEnabled = $Enabled
}

function Set-BusyState {
    param(
        [Parameter(Mandatory)]
        [bool]$Busy,

        [Parameter()]
        [string]$Mode = '',

        [Parameter()]
        [string]$Message = ''
    )

    $script:Busy = $Busy
    $script:BusyMode = $Mode
    Set-AppControlsEnabled -Enabled (-not $Busy)

    if ($Busy) {
        $script:CurrentAppText.Text = $Message
    }
    elseif ([string]::IsNullOrWhiteSpace($Message)) {
        $script:CurrentAppText.Text = 'No operation in progress'
    }
    else {
        $script:CurrentAppText.Text = $Message
    }
}

function Update-SearchPlaceholder {
    $script:SearchPlaceholder.Visibility = if ([string]::IsNullOrWhiteSpace($script:SearchBox.Text)) {
        [Windows.Visibility]::Visible
    }
    else {
        [Windows.Visibility]::Collapsed
    }
}

function Update-SelectedCount {
    $count = @($script:Apps | Where-Object { $_.IsSelected }).Count
    $script:SelectedCountText.Text = if ($count -le 1) {
        "$count application selected"
    }
    else {
        "$count applications selected"
    }
}

function Update-SummaryText {
    param(
        [Parameter()]
        [int]$Success = 0,

        [Parameter()]
        [int]$AlreadyInstalled = 0,

        [Parameter()]
        [int]$Skipped = 0,

        [Parameter()]
        [int]$Failed = 0
    )

    $script:SummaryText.Text = 'Successful {0} | Already installed {1} | Skipped {2} | Failed {3}' -f $Success, $AlreadyInstalled, $Skipped, $Failed
}

function Update-AppListView {
    $selectedCategory = [string]$script:CategoryList.SelectedItem
    if ([string]::IsNullOrWhiteSpace($selectedCategory)) {
        $selectedCategory = 'All applications'
    }

    $query = $script:SearchBox.Text
    $script:DisplayedApps.Clear()

    foreach ($app in $script:Apps) {
        $categoryMatches = ($selectedCategory -eq 'All applications' -or $app.Category -eq $selectedCategory)
        $searchMatches = $true

        if (-not [string]::IsNullOrWhiteSpace($query)) {
            $escaped = [regex]::Escape($query.Trim())
            $searchMatches = (
                $app.Name -match $escaped -or
                $app.Description -match $escaped -or
                $app.Category -match $escaped
            )
        }

        if ($categoryMatches -and $searchMatches) {
            [void]$script:DisplayedApps.Add($app)
        }
    }

    $script:AppGrid.Items.Refresh()
    Update-SelectedCount
    Update-SearchPlaceholder
}

function Set-ProfileSelection {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('All', 'None', 'Recommended')]
        [string]$Profile
    )

    $includeInstalled = [bool]$script:ReinstallInstalledCheck.IsChecked
    Select-AppProfile -Apps $script:Apps -Profile $Profile -IncludeInstalled $includeInstalled
    $script:AppGrid.Items.Refresh()
    Update-SelectedCount
}

function Set-AppStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter()]
        [bool]$IsInstalled,

        [Parameter()]
        [bool]$HasInstalledValue = $false,

        [Parameter()]
        [bool]$IsSelected,

        [Parameter()]
        [bool]$HasSelectedValue = $false,

        [Parameter()]
        [string]$Message = ''
    )

    if (-not $script:AppMap.ContainsKey($Id)) {
        return
    }

    $app = $script:AppMap[$Id]
    $app.Status = $Status
    $app.LastMessage = $Message

    if ($HasInstalledValue) {
        $app.IsInstalled = $IsInstalled
    }

    if ($HasSelectedValue) {
        $app.IsSelected = $IsSelected
    }
}

function Update-Progress {
    param(
        [Parameter()]
        [int]$Completed = 0,

        [Parameter()]
        [int]$Total = 0,

        [Parameter()]
        [string]$Current = '',

        [Parameter()]
        [string]$Text = ''
    )

    if ($Total -le 0) {
        $script:GlobalProgressBar.IsIndeterminate = $false
        $script:GlobalProgressBar.Value = 0
        $script:ProgressText.Text = if ([string]::IsNullOrWhiteSpace($Text)) { 'Ready' } else { $Text }
        return
    }

    $script:GlobalProgressBar.IsIndeterminate = $false
    $script:GlobalProgressBar.Maximum = $Total
    $script:GlobalProgressBar.Value = [Math]::Min($Completed, $Total)
    $percent = [Math]::Round(($Completed / [double]$Total) * 100)
    $script:ProgressText.Text = if ([string]::IsNullOrWhiteSpace($Text)) { "$percent %" } else { "$Text - $percent %" }

    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $script:CurrentAppText.Text = $Current
    }
}

function Stop-Worker {
    param(
        [Parameter()]
        [string]$Message = ''
    )

    if ($null -ne $script:WorkerPowerShell -and $null -ne $script:WorkerHandle) {
        try {
            $script:WorkerPowerShell.EndInvoke($script:WorkerHandle) | Out-Null
        }
        catch {
            Add-UiLog -Level 'ERROR' -Message "Background task error: $($_.Exception.Message)"
        }
    }

    if ($null -ne $script:WorkerPowerShell) {
        $script:WorkerPowerShell.Dispose()
    }

    $script:WorkerPowerShell = $null
    $script:WorkerHandle = $null
    $script:WorkerCompletionSeen = $true
    Set-BusyState -Busy $false -Message $Message
}

function Start-Worker {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [object[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($script:Busy) {
        [Windows.MessageBox]::Show('An operation is already in progress.', 'Windows Setup Manager', 'OK', 'Information') | Out-Null
        return
    }

    Set-BusyState -Busy $true -Mode $Mode -Message $Message
    $script:WorkerCompletionSeen = $false
    $script:WorkerPowerShell = [PowerShell]::Create()
    [void]$script:WorkerPowerShell.AddScript($ScriptBlock.ToString())

    foreach ($argument in $Arguments) {
        [void]$script:WorkerPowerShell.AddArgument($argument)
    }

    $script:WorkerHandle = $script:WorkerPowerShell.BeginInvoke()
}

function Start-Detection {
    if (-not $script:WingetAvailable) {
        [Windows.MessageBox]::Show('WinGet is unavailable. The check cannot start.', 'Windows Setup Manager', 'OK', 'Warning') | Out-Null
        return
    }

    foreach ($app in $script:Apps) {
        $app.Status = 'Pending'
    }
    $script:AppGrid.Items.Refresh()

    $worker = {
        param($apps, $projectRoot, $logger, $queue, $unselectInstalled)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Environment.ps1')
        . (Join-Path $sourceRoot 'Models.ps1')
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'Detection.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        try {
            $total = @($apps).Count
            $completed = 0
            $maxThreads = [Math]::Min(4, [Math]::Max(1, $total))
            & $logCallback 'INFO' "Checking installed applications in parallel ($maxThreads threads)."

            $pool = [RunspaceFactory]::CreateRunspacePool(1, $maxThreads)
            $pool.ApartmentState = 'MTA'
            $pool.Open()
            $pending = New-Object System.Collections.Generic.List[object]

            foreach ($app in @($apps)) {
                $queue.Enqueue([PSCustomObject]@{
                    Type      = 'Progress'
                    Completed = $completed
                    Total     = $total
                    Current   = "Checking: $($app.Name)"
                    Text      = "Check $($completed + 1) / $total"
                })

                $queue.Enqueue([PSCustomObject]@{
                    Type    = 'ItemStatus'
                    Id      = $app.Id
                    Status  = 'Checking...'
                    Message = 'Check in progress.'
                })

                $task = [PowerShell]::Create()
                $task.RunspacePool = $pool
                [void]$task.AddScript({
                    param($sourceRoot, $app)

                    . (Join-Path $sourceRoot 'Environment.ps1')
                    . (Join-Path $sourceRoot 'Models.ps1')
                    . (Join-Path $sourceRoot 'Detection.ps1')

                    try {
                        $state = Test-WingetPackageInstalled -PackageId $app.Id
                        [PSCustomObject]@{
                            Id        = $app.Id
                            Name      = $app.Name
                            Installed = [bool]$state.Installed
                            ExitCode  = $state.ExitCode
                            Message   = $state.Message
                            Error     = ''
                        }
                    }
                    catch {
                        [PSCustomObject]@{
                            Id        = $app.Id
                            Name      = $app.Name
                            Installed = $false
                            ExitCode  = 1
                            Message   = 'Error during check.'
                            Error     = $_.Exception.Message
                        }
                    }
                }.ToString())
                [void]$task.AddArgument($sourceRoot)
                [void]$task.AddArgument($app)
                $handle = $task.BeginInvoke()

                [void]$pending.Add([PSCustomObject]@{
                    PowerShell = $task
                    Handle     = $handle
                    App        = $app
                })
            }

            while ($pending.Count -gt 0) {
                for ($index = $pending.Count - 1; $index -ge 0; $index--) {
                    $entry = $pending[$index]
                    if (-not $entry.Handle.IsCompleted) {
                        continue
                    }

                    try {
                        $results = @($entry.PowerShell.EndInvoke($entry.Handle))
                        $state = $results | Select-Object -First 1
                    }
                    catch {
                        $state = [PSCustomObject]@{
                            Id        = $entry.App.Id
                            Name      = $entry.App.Name
                            Installed = $false
                            ExitCode  = 1
                            Message   = 'Error during check.'
                            Error     = $_.Exception.Message
                        }
                    }
                    finally {
                        $entry.PowerShell.Dispose()
                        $pending.RemoveAt($index)
                    }

                    $completed++

                    if (-not [string]::IsNullOrWhiteSpace($state.Error)) {
                        & $logCallback 'WARN' "Check for $($state.Name) incomplete: $($state.Error)"
                    }

                    if ($state.Installed) {
                        & $logCallback 'INFO' "$($state.Name) is already installed."
                        $queue.Enqueue([PSCustomObject]@{
                            Type              = 'ItemStatus'
                            Id                = $state.Id
                            Status            = 'Installed'
                            IsInstalled       = $true
                            HasInstalledValue = $true
                            IsSelected        = $false
                            HasSelectedValue  = $unselectInstalled
                            Message           = 'Application detected on this machine.'
                        })
                    }
                    else {
                        $queue.Enqueue([PSCustomObject]@{
                            Type              = 'ItemStatus'
                            Id                = $state.Id
                            Status            = 'To install'
                            IsInstalled       = $false
                            HasInstalledValue = $true
                            HasSelectedValue  = $false
                            Message           = 'Application not detected.'
                        })
                    }

                    $queue.Enqueue([PSCustomObject]@{
                        Type      = 'Progress'
                        Completed = $completed
                        Total     = $total
                        Current   = "Checking: $($state.Name)"
                        Text      = "Check $completed / $total"
                    })
                }

                Start-Sleep -Milliseconds 120
            }

            $pool.Close()
            $pool.Dispose()

            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Detection'
                Message = 'Check completed.'
            })
        }
        catch {
            if ($null -ne $pool) {
                try {
                    $pool.Close()
                    $pool.Dispose()
                }
                catch {
                    # The pool may already be closed if the error happens during cleanup.
                }
            }

            & $logCallback 'ERROR' "Check failed: $($_.Exception.Message)"
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Detection'
                Message = "Check interrupted: $($_.Exception.Message)"
            })
        }
    }

    $workerArguments = @(
        $script:Apps,
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue,
        (-not [bool]$script:ReinstallInstalledCheck.IsChecked)
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'Detection' -Message 'Checking applications...'
}

function Start-Installation {
    if (-not $script:WingetAvailable) {
        [Windows.MessageBox]::Show('WinGet is unavailable. Installation cannot start.', 'Windows Setup Manager', 'OK', 'Warning') | Out-Null
        return
    }

    $selectedApps = @(Get-SelectedApps -Apps $script:Apps)
    if ($selectedApps.Count -eq 0) {
        [Windows.MessageBox]::Show('Select at least one application to install.', 'Windows Setup Manager', 'OK', 'Information') | Out-Null
        return
    }

    $needsAdmin = @($selectedApps | Where-Object { $_.RequiresAdmin })
    if ($needsAdmin.Count -gt 0 -and -not $script:IsAdministrator) {
        $answer = [Windows.MessageBox]::Show(
            "Some selected applications may require administrator privileges and could fail in a standard session.`n`nUse the 'Restart as admin' button at the top if you want elevation before installing.`n`nContinue in the current session?",
            'Administrator privileges',
            'OKCancel',
            'Warning'
        )

        if ($answer -ne [Windows.MessageBoxResult]::OK) {
            return
        }
    }

    foreach ($app in $selectedApps) {
        $app.Status = 'Pending'
    }
    $script:AppGrid.Items.Refresh()
    Update-SummaryText

    $worker = {
        param($apps, $projectRoot, $logger, $queue, $reinstallInstalled)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Environment.ps1')
        . (Join-Path $sourceRoot 'Models.ps1')
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'Detection.ps1')
        . (Join-Path $sourceRoot 'Installer.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        $summary = [ordered]@{
            Success          = 0
            AlreadyInstalled = 0
            Skipped          = 0
            Failed           = 0
        }

        try {
            $total = @($apps).Count
            $completed = 0
            & $logCallback 'INFO' "Installing $total application(s)."

            foreach ($app in @($apps)) {
                $queue.Enqueue([PSCustomObject]@{
                    Type      = 'Progress'
                    Completed = $completed
                    Total     = $total
                    Current   = "Installing: $($app.Name)"
                    Text      = "Installation $($completed + 1) / $total"
                })
                $queue.Enqueue([PSCustomObject]@{
                    Type   = 'ItemStatus'
                    Id     = $app.Id
                    Status = 'Installation...'
                })

                $result = Install-WingetPackage `
                    -Id $app.Id `
                    -Name $app.Name `
                    -VerifyCommand $app.VerifyCommand `
                    -ReinstallInstalled $reinstallInstalled `
                    -RequiresAdmin $app.RequiresAdmin `
                    -LogCallback $logCallback

                $completed++

                if ($result.AlreadyInstalled) {
                    $summary.AlreadyInstalled++
                    $queue.Enqueue([PSCustomObject]@{
                        Type              = 'ItemStatus'
                        Id                = $app.Id
                        Status            = 'Already installed'
                        IsInstalled       = $true
                        HasInstalledValue = $true
                        Message           = $result.Message
                    })
                }
                elseif ($result.Success) {
                    $summary.Success++
                    $queue.Enqueue([PSCustomObject]@{
                        Type              = 'ItemStatus'
                        Id                = $app.Id
                        Status            = 'Installed'
                        IsInstalled       = $true
                        HasInstalledValue = $true
                        Message           = $result.Message
                    })
                }
                elseif ($result.Skipped) {
                    $summary.Skipped++
                    $queue.Enqueue([PSCustomObject]@{
                        Type    = 'ItemStatus'
                        Id      = $app.Id
                        Status  = 'Skipped'
                        Message = $result.Message
                    })
                }
                else {
                    $summary.Failed++
                    $queue.Enqueue([PSCustomObject]@{
                        Type    = 'ItemStatus'
                        Id      = $app.Id
                        Status  = 'Failed'
                        Message = $result.Message
                    })
                }

                $queue.Enqueue([PSCustomObject]@{
                    Type      = 'Progress'
                    Completed = $completed
                    Total     = $total
                    Current   = "Completed: $($app.Name)"
                    Text      = "Installation $completed / $total"
                })
            }

            $queue.Enqueue([PSCustomObject]@{
                Type              = 'Complete'
                Mode              = 'Installation'
                Message           = 'Installation completed.'
                Success           = $summary.Success
                AlreadyInstalled  = $summary.AlreadyInstalled
                Skipped           = $summary.Skipped
                Failed            = $summary.Failed
            })
        }
        catch {
            & $logCallback 'ERROR' "Installation interrupted: $($_.Exception.Message)"
            $queue.Enqueue([PSCustomObject]@{
                Type              = 'Complete'
                Mode              = 'Installation'
                Message           = "Installation interrupted: $($_.Exception.Message)"
                Success           = $summary.Success
                AlreadyInstalled  = $summary.AlreadyInstalled
                Skipped           = $summary.Skipped
                Failed            = $summary.Failed + 1
            })
        }
    }

    $workerArguments = @(
        $selectedApps,
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue,
        ([bool]$script:ReinstallInstalledCheck.IsChecked)
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'Installation' -Message 'Installation in progress...'
}

function Start-UpgradeAll {
    if (-not $script:WingetAvailable) {
        [Windows.MessageBox]::Show('WinGet is unavailable. The update cannot start.', 'Windows Setup Manager', 'OK', 'Warning') | Out-Null
        return
    }

    $answer = [Windows.MessageBox]::Show(
        "Start the global update with WinGet?`n`nCommand: winget upgrade --all --silent --accept-package-agreements --accept-source-agreements",
        'Confirm update',
        'YesNo',
        'Question'
    )

    if ($answer -ne [Windows.MessageBoxResult]::Yes) {
        return
    }

    $worker = {
        param($projectRoot, $logger, $queue)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Environment.ps1')
        . (Join-Path $sourceRoot 'Models.ps1')
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'Detection.ps1')
        . (Join-Path $sourceRoot 'Installer.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        try {
            $queue.Enqueue([PSCustomObject]@{ Type = 'IndeterminateProgress'; Text = 'Global update in progress...'; Current = 'WinGet upgrade --all' })
            $result = Invoke-WingetUpgradeAll -LogCallback $logCallback
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Upgrade'
                Message = $result.Message
                Success = if ($result.Success) { 1 } else { 0 }
                Failed  = if ($result.Success) { 0 } else { 1 }
            })
        }
        catch {
            & $logCallback 'ERROR' "Update interrupted: $($_.Exception.Message)"
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Upgrade'
                Message = "Update interrupted: $($_.Exception.Message)"
                Success = 0
                Failed  = 1
            })
        }
    }

    $workerArguments = @(
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'Upgrade' -Message 'Global update in progress...'
}

function Start-Win11Debloat {
    $answer = [Windows.MessageBox]::Show(
        "Windows Setup Manager will download Win11Debloat from the official GitHub repository, extract it into the local external folder, and launch Win11Debloat.ps1 in a separate PowerShell window.`n`nWin11Debloat can remove built-in apps and change Windows privacy, update, Explorer, taskbar, and other system settings. Read its prompts carefully before applying changes.`n`nContinue?",
        'Run Win11Debloat',
        'YesNo',
        'Warning'
    )

    if ($answer -ne [Windows.MessageBoxResult]::Yes) {
        return
    }

    $worker = {
        param($projectRoot, $logger, $queue, $isAdministrator)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'ExternalTools.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        try {
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'IndeterminateProgress'
                Text    = 'Fetching Win11Debloat...'
                Current = 'Downloading official GitHub archive'
            })

            $result = Invoke-Win11Debloat `
                -ProjectRoot $projectRoot `
                -RunAsAdministrator (-not [bool]$isAdministrator) `
                -LogCallback $logCallback

            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Win11Debloat'
                Message = $result.Message
                Success = if ($result.Success) { 1 } else { 0 }
                Failed  = if ($result.Success) { 0 } else { 1 }
            })
        }
        catch {
            & $logCallback 'ERROR' "Win11Debloat failed: $($_.Exception.Message)"
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'Win11Debloat'
                Message = "Win11Debloat failed: $($_.Exception.Message)"
                Success = 0
                Failed  = 1
            })
        }
    }

    $workerArguments = @(
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue,
        $script:IsAdministrator
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'Win11Debloat' -Message 'Fetching Win11Debloat...'
}

function Open-WindowsActivationSettings {
    try {
        Add-UiLog -Level 'INFO' -Message 'Opening Windows activation settings.'
        Start-Process 'ms-settings:activation'
    }
    catch {
        Add-UiLog -Level 'ERROR' -Message "Unable to open Windows activation settings: $($_.Exception.Message)"
        [Windows.MessageBox]::Show($_.Exception.Message, 'Activation settings', 'OK', 'Error') | Out-Null
    }
}

function Start-CustomScript {
    $scriptPath = Get-CustomScriptPath -ProjectRoot $script:ProjectRoot
    $runAsAdministrator = $false

    if ($script:IsAdministrator) {
        $answer = [Windows.MessageBox]::Show(
            "Run the local custom script now?`n`nPath: $scriptPath`n`nOnly run scripts you wrote or trust.",
            'Run custom script',
            'YesNo',
            'Warning'
        )

        if ($answer -ne [Windows.MessageBoxResult]::Yes) {
            return
        }

        $runAsAdministrator = $false
    }
    else {
        $answer = [Windows.MessageBox]::Show(
            "Run the local custom script now?`n`nPath: $scriptPath`n`nYes: run as administrator`nNo: run in the current session`nCancel: do not run",
            'Run custom script',
            'YesNoCancel',
            'Warning'
        )

        if ($answer -eq [Windows.MessageBoxResult]::Cancel) {
            return
        }

        $runAsAdministrator = ($answer -eq [Windows.MessageBoxResult]::Yes)
    }

    $worker = {
        param($projectRoot, $logger, $queue, $runAsAdministrator)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'ExternalTools.ps1')
        . (Join-Path $sourceRoot 'CustomScripts.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        try {
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'IndeterminateProgress'
                Text    = 'Custom script in progress...'
                Current = 'custom\CustomScript.ps1'
            })

            $result = Invoke-CustomScript `
                -ProjectRoot $projectRoot `
                -RunAsAdministrator ([bool]$runAsAdministrator) `
                -LogCallback $logCallback

            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'CustomScript'
                Message = $result.Message
                Success = if ($result.Success) { 1 } else { 0 }
                Failed  = if ($result.Success) { 0 } else { 1 }
            })
        }
        catch {
            & $logCallback 'ERROR' "Custom script failed: $($_.Exception.Message)"
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'CustomScript'
                Message = "Custom script failed: $($_.Exception.Message)"
                Success = 0
                Failed  = 1
            })
        }
    }

    $workerArguments = @(
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue,
        $runAsAdministrator
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'CustomScript' -Message 'Custom script in progress...'
}

function Set-StatusTextBrush {
    param(
        [Parameter(Mandatory)]
        [object]$TextBlock,

        [Parameter(Mandatory)]
        [ValidateSet('Neutral', 'Success', 'Warning', 'Error')]
        [string]$Kind
    )

    $TextBlock.Foreground = switch ($Kind) {
        'Success' { [Windows.Media.Brushes]::LightGreen }
        'Warning' { [Windows.Media.Brushes]::Khaki }
        'Error' { [Windows.Media.Brushes]::Tomato }
        default { [Windows.Media.Brushes]::LightGray }
    }
}

function Update-VmDeploymentStatus {
    param(
        [Parameter()]
        [object]$Status
    )

    if ($null -eq $Status) {
        $Status = Get-VmDeploymentStatus
    }

    $environment = $Status.Environment
    $identity = @($environment.Manufacturer, $environment.Model) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    if ($environment.IsVirtual) {
        $script:VmEnvironmentText.Text = "Environment: $($environment.Type) VM - $($identity -join ' / ')"
        Set-StatusTextBrush -TextBlock $script:VmEnvironmentText -Kind 'Success'
    }
    else {
        $script:VmEnvironmentText.Text = if ($identity.Count -gt 0) {
            "Environment: physical or unknown - $($identity -join ' / ')"
        }
        else {
            'Environment: physical or unknown'
        }
        Set-StatusTextBrush -TextBlock $script:VmEnvironmentText -Kind 'Neutral'
    }

    $vmwareText = $Status.VMwareTools.Message
    $vmwareKind = if ($Status.VMwareTools.Installed) { 'Success' } else { 'Warning' }
    if (-not $Status.VMwareTools.Installed) {
        if ($null -ne $Status.VMwareInstaller) {
            $vmwareText = 'ISO mounted, ready to install'
            $vmwareKind = 'Success'
        }
        elseif (-not $environment.IsVMware) {
            $vmwareText = 'Not a VMware VM'
            $vmwareKind = 'Neutral'
        }
        else {
            $vmwareText = 'ISO not mounted'
        }
    }
    $script:VmwareToolsStatusText.Text = $vmwareText
    Set-StatusTextBrush -TextBlock $script:VmwareToolsStatusText -Kind $vmwareKind

    $virtualBoxText = $Status.VirtualBoxAdditions.Message
    $virtualBoxKind = if ($Status.VirtualBoxAdditions.Installed) { 'Success' } else { 'Warning' }
    if (-not $Status.VirtualBoxAdditions.Installed) {
        if ($null -ne $Status.VirtualBoxInstaller) {
            $virtualBoxText = 'ISO mounted, ready to install'
            $virtualBoxKind = 'Success'
        }
        elseif (-not $environment.IsVirtualBox) {
            $virtualBoxText = 'Not a VirtualBox VM'
            $virtualBoxKind = 'Neutral'
        }
        else {
            $virtualBoxText = 'ISO not mounted'
        }
    }
    $script:VirtualBoxToolsStatusText.Text = $virtualBoxText
    Set-StatusTextBrush -TextBlock $script:VirtualBoxToolsStatusText -Kind $virtualBoxKind

    $rdpText = if ($Status.RemoteDesktop.Enabled) {
        if ($Status.RemoteDesktop.NlaEnabled -and $Status.RemoteDesktop.FirewallEnabled) {
            'Enabled with NLA'
        }
        else {
            'Enabled, check firewall/NLA'
        }
    }
    else {
        $Status.RemoteDesktop.Message
    }
    $rdpKind = if ($Status.RemoteDesktop.Enabled -and $Status.RemoteDesktop.NlaEnabled -and $Status.RemoteDesktop.FirewallEnabled) {
        'Success'
    }
    elseif (-not $Status.RemoteDesktop.Supported) {
        'Error'
    }
    else {
        'Warning'
    }
    $script:RemoteDesktopStatusText.Text = $rdpText
    Set-StatusTextBrush -TextBlock $script:RemoteDesktopStatusText -Kind $rdpKind

    $script:StickyKeysStatusText.Text = $Status.StickyAndFilterKeys.Message
    Set-StatusTextBrush -TextBlock $script:StickyKeysStatusText -Kind $(if ($Status.StickyAndFilterKeys.Disabled) { 'Success' } else { 'Warning' })
}

function Confirm-AdministratorForAction {
    param(
        [Parameter(Mandatory)]
        [string]$ActionName
    )

    if ($script:IsAdministrator) {
        return $true
    }

    $answer = [Windows.MessageBox]::Show(
        "$ActionName requires administrator privileges. Restart Windows Setup Manager as administrator now?",
        'Administrator privileges required',
        'YesNo',
        'Warning'
    )

    if ($answer -eq [Windows.MessageBoxResult]::Yes) {
        Restart-AsAdministrator -ScriptPath $script:EntryPoint
        $script:Window.Close()
    }

    $false
}

function Start-VmDeploymentAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RefreshStatus', 'InstallVmwareTools', 'InstallVirtualBoxAdditions', 'EnableRemoteDesktop', 'DisableStickyKeys')]
        [string]$Action
    )

    $requiresAdmin = $Action -in @('InstallVmwareTools', 'InstallVirtualBoxAdditions', 'EnableRemoteDesktop')
    $displayName = switch ($Action) {
        'RefreshStatus' { 'Refresh VM status' }
        'InstallVmwareTools' { 'Install VMware Tools' }
        'InstallVirtualBoxAdditions' { 'Install VirtualBox Guest Additions' }
        'EnableRemoteDesktop' { 'Enable Remote Desktop' }
        'DisableStickyKeys' { 'Disable Sticky/Filter Keys shortcuts' }
    }

    if ($requiresAdmin -and -not (Confirm-AdministratorForAction -ActionName $displayName)) {
        return
    }

    if ($Action -ne 'RefreshStatus') {
        $message = switch ($Action) {
            'InstallVmwareTools' {
                "Mount the VMware Tools ISO from your hypervisor before continuing. Windows Setup Manager will run the installer found on that ISO in silent mode.`n`nContinue?"
            }
            'InstallVirtualBoxAdditions' {
                "Mount the VirtualBox Guest Additions ISO before continuing. Windows Setup Manager will run VBoxWindowsAdditions.exe from that ISO in silent mode.`n`nContinue?"
            }
            'EnableRemoteDesktop' {
                "Remote Desktop opens inbound access to this machine. Use it only on trusted networks and ensure remote users have strong passwords.`n`nContinue?"
            }
            'DisableStickyKeys' {
                "This will disable Sticky Keys and Filter Keys shortcuts for the current user, and for the logon/default user when permissions allow it.`n`nContinue?"
            }
        }

        $answer = [Windows.MessageBox]::Show($message, $displayName, 'YesNo', 'Question')
        if ($answer -ne [Windows.MessageBoxResult]::Yes) {
            return
        }
    }

    $worker = {
        param($action, $projectRoot, $logger, $queue)

        $sourceRoot = Join-Path $projectRoot 'src'
        . (Join-Path $sourceRoot 'Logging.ps1')
        . (Join-Path $sourceRoot 'VmDeployment.ps1')

        $logCallback = {
            param($level, $message)
            $line = Write-Log -Logger $logger -Level $level -Message $message
            $queue.Enqueue([PSCustomObject]@{ Type = 'Log'; Line = $line })
        }

        $displayName = switch ($action) {
            'RefreshStatus' { 'VM status refresh' }
            'InstallVmwareTools' { 'VMware Tools installation' }
            'InstallVirtualBoxAdditions' { 'VirtualBox Guest Additions installation' }
            'EnableRemoteDesktop' { 'Remote Desktop configuration' }
            'DisableStickyKeys' { 'Sticky/Filter Keys configuration' }
        }

        try {
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'IndeterminateProgress'
                Text    = "$displayName in progress..."
                Current = $displayName
            })

            $result = switch ($action) {
                'RefreshStatus' {
                    & $logCallback 'INFO' 'Refreshing VM deployment status.'
                    [PSCustomObject]@{ Success = $true; Message = 'VM deployment status refreshed.' }
                }
                'InstallVmwareTools' {
                    Invoke-VMwareToolsInstall -LogCallback $logCallback
                }
                'InstallVirtualBoxAdditions' {
                    Invoke-VirtualBoxGuestAdditionsInstall -LogCallback $logCallback
                }
                'EnableRemoteDesktop' {
                    Enable-RemoteDesktopAccess -LogCallback $logCallback
                }
                'DisableStickyKeys' {
                    Disable-StickyAndFilterKeysShortcuts -IncludeDefaultProfile $true -LogCallback $logCallback
                }
            }

            $status = Get-VmDeploymentStatus
            $queue.Enqueue([PSCustomObject]@{ Type = 'VmStatus'; Status = $status })
            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'VmDeployment'
                Message = $result.Message
                Success = if ($result.Success) { 1 } else { 0 }
                Failed  = if ($result.Success) { 0 } else { 1 }
            })
        }
        catch {
            & $logCallback 'ERROR' "$displayName failed: $($_.Exception.Message)"
            try {
                $status = Get-VmDeploymentStatus
                $queue.Enqueue([PSCustomObject]@{ Type = 'VmStatus'; Status = $status })
            }
            catch {
                & $logCallback 'WARN' "Unable to refresh VM deployment status: $($_.Exception.Message)"
            }

            $queue.Enqueue([PSCustomObject]@{
                Type    = 'Complete'
                Mode    = 'VmDeployment'
                Message = "$displayName failed: $($_.Exception.Message)"
                Success = 0
                Failed  = 1
            })
        }
    }

    $workerArguments = @(
        $Action,
        $script:ProjectRoot,
        $script:Logger,
        $script:EventQueue
    )

    Start-Worker -ScriptBlock $worker -Arguments $workerArguments -Mode 'VmDeployment' -Message "$displayName in progress..."
}

function Drain-EventQueue {
    $needsRefresh = $false
    $item = $null

    while ($script:EventQueue.TryDequeue([ref]$item)) {
        switch ($item.Type) {
            'Log' {
                $script:LogBox.AppendText($item.Line + [Environment]::NewLine)
                $script:LogBox.ScrollToEnd()
            }
            'Progress' {
                Update-Progress -Completed $item.Completed -Total $item.Total -Current $item.Current -Text $item.Text
            }
            'IndeterminateProgress' {
                $script:GlobalProgressBar.IsIndeterminate = $true
                $script:ProgressText.Text = $item.Text
                $script:CurrentAppText.Text = $item.Current
            }
            'ItemStatus' {
                Set-AppStatus `
                    -Id $item.Id `
                    -Status $item.Status `
                    -IsInstalled ([bool]$item.IsInstalled) `
                    -HasInstalledValue ([bool]$item.HasInstalledValue) `
                    -IsSelected ([bool]$item.IsSelected) `
                    -HasSelectedValue ([bool]$item.HasSelectedValue) `
                    -Message $item.Message
                $needsRefresh = $true
            }
            'VmStatus' {
                Update-VmDeploymentStatus -Status $item.Status
            }
            'Complete' {
                $script:GlobalProgressBar.IsIndeterminate = $false
                $script:CurrentAppText.Text = $item.Message
                if ($null -ne $item.Success -or $null -ne $item.Failed) {
                    Update-SummaryText `
                        -Success ([int]$item.Success) `
                        -AlreadyInstalled ([int]$item.AlreadyInstalled) `
                        -Skipped ([int]$item.Skipped) `
                        -Failed ([int]$item.Failed)
                }
                Add-UiLog -Level 'INFO' -Message $item.Message
                Stop-Worker -Message $item.Message
            }
        }

        $item = $null
    }

    if ($needsRefresh) {
        $script:AppGrid.Items.Refresh()
    }

    Update-SelectedCount

    if (-not $script:WorkerCompletionSeen -and $null -ne $script:WorkerHandle -and $script:WorkerHandle.IsCompleted) {
        Stop-Worker
    }
}

function Initialize-Window {
    $xamlPath = Join-Path $script:SourceRoot 'MainWindow.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)

    $script:WingetStatusText = Get-NamedControl 'WingetStatusText'
    $script:AdminStatusText = Get-NamedControl 'AdminStatusText'
    $script:RestartAdminButton = Get-NamedControl 'RestartAdminButton'
    $script:CategoryList = Get-NamedControl 'CategoryList'
    $script:SearchBox = Get-NamedControl 'SearchBox'
    $script:SearchPlaceholder = Get-NamedControl 'SearchPlaceholder'
    $script:AppGrid = Get-NamedControl 'AppGrid'
    $script:SelectAllButton = Get-NamedControl 'SelectAllButton'
    $script:ClearSelectionButton = Get-NamedControl 'ClearSelectionButton'
    $script:RecommendedButton = Get-NamedControl 'RecommendedButton'
    $script:ReinstallInstalledCheck = Get-NamedControl 'ReinstallInstalledCheck'
    $script:SelectedCountText = Get-NamedControl 'SelectedCountText'
    $script:ProgressText = Get-NamedControl 'ProgressText'
    $script:CurrentAppText = Get-NamedControl 'CurrentAppText'
    $script:GlobalProgressBar = Get-NamedControl 'GlobalProgressBar'
    $script:SummaryText = Get-NamedControl 'SummaryText'
    $script:LogBox = Get-NamedControl 'LogBox'
    $script:VmEnvironmentText = Get-NamedControl 'VmEnvironmentText'
    $script:VmwareToolsStatusText = Get-NamedControl 'VmwareToolsStatusText'
    $script:VirtualBoxToolsStatusText = Get-NamedControl 'VirtualBoxToolsStatusText'
    $script:RemoteDesktopStatusText = Get-NamedControl 'RemoteDesktopStatusText'
    $script:StickyKeysStatusText = Get-NamedControl 'StickyKeysStatusText'
    $script:VerifyButton = Get-NamedControl 'VerifyButton'
    $script:UpgradeButton = Get-NamedControl 'UpgradeButton'
    $script:Win11DebloatButton = Get-NamedControl 'Win11DebloatButton'
    $script:CustomScriptButton = Get-NamedControl 'CustomScriptButton'
    $script:ActivationSettingsButton = Get-NamedControl 'ActivationSettingsButton'
    $script:RefreshVmStatusButton = Get-NamedControl 'RefreshVmStatusButton'
    $script:InstallVmwareToolsButton = Get-NamedControl 'InstallVmwareToolsButton'
    $script:InstallVirtualBoxToolsButton = Get-NamedControl 'InstallVirtualBoxToolsButton'
    $script:EnableRemoteDesktopButton = Get-NamedControl 'EnableRemoteDesktopButton'
    $script:DisableStickyKeysButton = Get-NamedControl 'DisableStickyKeysButton'
    $script:InstallButton = Get-NamedControl 'InstallButton'

    $iconPath = Join-Path $script:ProjectRoot 'assets\icon.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $iconUri = New-Object System.Uri -ArgumentList $iconPath, ([System.UriKind]::Absolute)
            $script:Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
        }
        catch {
            Add-UiLog -Level 'WARN' -Message "Icon not loaded: $($_.Exception.Message)"
        }
    }

    $script:AppGrid.ItemsSource = $script:DisplayedApps
    $script:CategoryList.Add_SelectionChanged({ Update-AppListView })
    $script:SearchBox.Add_TextChanged({ Update-AppListView })
    $script:SelectAllButton.Add_Click({ Set-ProfileSelection -Profile 'All' })
    $script:ClearSelectionButton.Add_Click({ Set-ProfileSelection -Profile 'None' })
    $script:RecommendedButton.Add_Click({ Set-ProfileSelection -Profile 'Recommended' })
    $script:VerifyButton.Add_Click({ Start-Detection })
    $script:InstallButton.Add_Click({ Start-Installation })
    $script:UpgradeButton.Add_Click({ Start-UpgradeAll })
    $script:Win11DebloatButton.Add_Click({ Start-Win11Debloat })
    $script:CustomScriptButton.Add_Click({ Start-CustomScript })
    $script:ActivationSettingsButton.Add_Click({ Open-WindowsActivationSettings })
    $script:RefreshVmStatusButton.Add_Click({ Start-VmDeploymentAction -Action 'RefreshStatus' })
    $script:InstallVmwareToolsButton.Add_Click({ Start-VmDeploymentAction -Action 'InstallVmwareTools' })
    $script:InstallVirtualBoxToolsButton.Add_Click({ Start-VmDeploymentAction -Action 'InstallVirtualBoxAdditions' })
    $script:EnableRemoteDesktopButton.Add_Click({ Start-VmDeploymentAction -Action 'EnableRemoteDesktop' })
    $script:DisableStickyKeysButton.Add_Click({ Start-VmDeploymentAction -Action 'DisableStickyKeys' })
    $script:RestartAdminButton.Add_Click({
        Restart-AsAdministrator -ScriptPath $script:EntryPoint
        $script:Window.Close()
    })

    $script:Window.Add_Closing({
        if ($script:Busy) {
            $answer = [Windows.MessageBox]::Show(
                'An operation is in progress. Closing the window may not stop the WinGet process that has already started. Do you want to close?',
                'Operation in progress',
                'YesNo',
                'Warning'
            )

            if ($answer -ne [Windows.MessageBoxResult]::Yes) {
                $_.Cancel = $true
            }
        }
    })

    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({ Drain-EventQueue })
    $script:Timer.Start()
}

function Initialize-AppState {
    Add-UiLog -Level 'INFO' -Message 'Starting Windows Setup Manager.'

    try {
        $script:Apps = @(Import-AppCatalog -Path $script:AppCatalogPath)
        $script:AppMap = @{}
        foreach ($app in $script:Apps) {
            $script:AppMap[$app.Id] = $app
        }

        $script:CatalogLoaded = $true
        $categories = Get-AppCategories -Apps $script:Apps
        $script:CategoryList.ItemsSource = $categories
        $script:CategoryList.SelectedIndex = 0
        Update-AppListView
        Add-UiLog -Level 'INFO' -Message "$($script:Apps.Count) applications loaded from apps.json."
    }
    catch {
        Add-UiLog -Level 'ERROR' -Message $_.Exception.Message
        [Windows.MessageBox]::Show($_.Exception.Message, 'Invalid catalog', 'OK', 'Error') | Out-Null
        $script:Apps = @()
        Set-AppControlsEnabled -Enabled $false
    }

    $wingetStatus = Get-WingetStatus
    $script:WingetAvailable = [bool]$wingetStatus.IsAvailable

    if ($script:WingetAvailable) {
        $script:WingetStatusText.Text = "WinGet $($wingetStatus.Version)"
        $script:WingetStatusText.Foreground = [Windows.Media.Brushes]::LightGreen
        Add-UiLog -Level 'INFO' -Message $wingetStatus.Message
    }
    else {
        $script:WingetStatusText.Text = 'WinGet unavailable'
        $script:WingetStatusText.Foreground = [Windows.Media.Brushes]::Tomato
        Add-UiLog -Level 'ERROR' -Message $wingetStatus.Message
        [Windows.MessageBox]::Show($wingetStatus.Message, 'WinGet required', 'OK', 'Warning') | Out-Null
    }

    if ($script:IsAdministrator) {
        $script:AdminStatusText.Text = 'Administrator'
        $script:RestartAdminButton.Visibility = [Windows.Visibility]::Collapsed
    }
    else {
        $script:AdminStatusText.Text = 'Standard session'
        $script:RestartAdminButton.Visibility = [Windows.Visibility]::Visible
    }

    try {
        Update-VmDeploymentStatus
        Add-UiLog -Level 'INFO' -Message 'VM deployment status loaded.'
    }
    catch {
        Add-UiLog -Level 'WARN' -Message "VM deployment status unavailable: $($_.Exception.Message)"
    }

    Set-AppControlsEnabled -Enabled $script:CatalogLoaded
    Update-SelectedCount
}

Initialize-Window
Initialize-AppState

if ($script:CatalogLoaded -and $script:WingetAvailable -and $script:Apps.Count -gt 0) {
    $script:Window.Dispatcher.BeginInvoke([Action]{ Start-Detection }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
}

[void]$script:Window.ShowDialog()
