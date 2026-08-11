#requires -Version 5.1

function Write-VmDeploymentLog {
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

function Get-VMEnvironment {
    [CmdletBinding()]
    param()

    $manufacturer = ''
    $model = ''
    $biosVersion = ''

    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = [string]$computerSystem.Manufacturer
        $model = [string]$computerSystem.Model
    }
    catch {
        # Keep empty values; callers still receive a usable status object.
    }

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $biosVersion = [string]($bios.SMBIOSBIOSVersion, $bios.Version -join ' ')
    }
    catch {
        # BIOS details are optional.
    }

    $fingerprint = "$manufacturer $model $biosVersion"
    $type = 'Unknown'

    if ($fingerprint -match '(?i)vmware') {
        $type = 'VMware'
    }
    elseif ($fingerprint -match '(?i)virtualbox|oracle') {
        $type = 'VirtualBox'
    }
    elseif ($fingerprint -match '(?i)microsoft.*virtual|virtual machine|hyper-v') {
        $type = 'Hyper-V'
    }
    elseif ($fingerprint -match '(?i)qemu|kvm') {
        $type = 'QEMU/KVM'
    }
    elseif ($fingerprint -match '(?i)xen') {
        $type = 'Xen'
    }
    elseif ($fingerprint -match '(?i)parallels') {
        $type = 'Parallels'
    }

    [PSCustomObject]@{
        Type         = $type
        IsVirtual    = ($type -ne 'Unknown')
        IsVMware     = ($type -eq 'VMware')
        IsVirtualBox = ($type -eq 'VirtualBox')
        Manufacturer = $manufacturer
        Model        = $model
        BiosVersion  = $biosVersion
    }
}

function Get-CDDriveInfo {
    [CmdletBinding()]
    param()

    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 5' -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DeviceID) } |
            ForEach-Object {
                [PSCustomObject]@{
                    Drive      = ([string]$_.DeviceID).TrimEnd('\')
                    Root       = (([string]$_.DeviceID).TrimEnd('\') + '\')
                    VolumeName = [string]$_.VolumeName
                }
            }
    }
    catch {
        @()
    }
}

function Find-VMwareToolsInstaller {
    [CmdletBinding()]
    param()

    foreach ($drive in @(Get-CDDriveInfo)) {
        $setup64 = Join-Path $drive.Root 'setup64.exe'
        $setup = Join-Path $drive.Root 'setup.exe'
        $msi = Join-Path $drive.Root 'VMware Tools.msi'

        $looksLikeVmware = (
            $drive.VolumeName -match '(?i)vmware|vmtools' -or
            (Test-Path -LiteralPath $msi) -or
            (Test-Path -LiteralPath (Join-Path $drive.Root 'VMwareToolsUpgrader.exe'))
        )

        if ($looksLikeVmware -and (Test-Path -LiteralPath $setup64)) {
            return [PSCustomObject]@{
                Path       = $setup64
                Drive      = $drive.Drive
                VolumeName = $drive.VolumeName
            }
        }

        if ($looksLikeVmware -and (Test-Path -LiteralPath $setup)) {
            return [PSCustomObject]@{
                Path       = $setup
                Drive      = $drive.Drive
                VolumeName = $drive.VolumeName
            }
        }
    }

    $null
}

function Find-VirtualBoxGuestAdditionsInstaller {
    [CmdletBinding()]
    param()

    foreach ($drive in @(Get-CDDriveInfo)) {
        $installer = Join-Path $drive.Root 'VBoxWindowsAdditions.exe'
        $looksLikeVirtualBox = (
            $drive.VolumeName -match '(?i)vbox|virtualbox|guest' -or
            (Test-Path -LiteralPath (Join-Path $drive.Root 'VBoxWindowsAdditions-amd64.exe')) -or
            (Test-Path -LiteralPath (Join-Path $drive.Root 'VBoxWindowsAdditions-x86.exe'))
        )

        if ($looksLikeVirtualBox -and (Test-Path -LiteralPath $installer)) {
            return [PSCustomObject]@{
                Path       = $installer
                Drive      = $drive.Drive
                VolumeName = $drive.VolumeName
            }
        }
    }

    $null
}

function Test-VMwareToolsInstalled {
    [CmdletBinding()]
    param()

    $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
    $installed = ($null -ne $service)
    $version = ''

    foreach ($path in @(
        'HKLM:\SOFTWARE\VMware, Inc.\VMware Tools',
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Tools'
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$properties.Version)) {
                $version = [string]$properties.Version
                break
            }
        }
        catch {
            # Version is optional.
        }
    }

    [PSCustomObject]@{
        Installed = [bool]$installed
        Service   = if ($installed) { $service.Status.ToString() } else { 'Missing' }
        Version   = $version
        Message   = if ($installed) { "Installed ($($service.Status))" } else { 'Not installed' }
    }
}

function Test-VirtualBoxGuestAdditionsInstalled {
    [CmdletBinding()]
    param()

    $service = Get-Service -Name 'VBoxService' -ErrorAction SilentlyContinue
    $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $filePresent = $false

    foreach ($root in $programFiles) {
        $candidate = Join-Path $root 'Oracle\VirtualBox Guest Additions\VBoxService.exe'
        if (Test-Path -LiteralPath $candidate) {
            $filePresent = $true
            break
        }
    }

    $installed = ($null -ne $service -or $filePresent)

    [PSCustomObject]@{
        Installed = [bool]$installed
        Service   = if ($null -ne $service) { $service.Status.ToString() } else { 'Missing' }
        Message   = if ($installed) { if ($null -ne $service) { "Installed ($($service.Status))" } else { 'Installed' } } else { 'Not installed' }
    }
}

function Test-RemoteDesktopEnabled {
    [CmdletBinding()]
    param()

    $caption = ''
    try {
        $caption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    }
    catch {
        # Edition details are optional.
    }

    $isHomeEdition = ($caption -match '(?i)\bhome\b')
    $denyConnections = $null
    $nla = $null

    try {
        $denyConnections = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction Stop).fDenyTSConnections
    }
    catch {
        $denyConnections = $null
    }

    try {
        $nla = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -ErrorAction Stop).UserAuthentication
    }
    catch {
        $nla = $null
    }

    $firewallRules = @()
    try {
        $firewallRules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.Name -like 'RemoteDesktop-*' -or
            $_.DisplayGroup -eq 'Remote Desktop' -or
            $_.Group -eq '@FirewallAPI.dll,-28752'
        })
    }
    catch {
        $firewallRules = @()
    }

    $firewallEnabled = ($firewallRules.Count -gt 0 -and @($firewallRules | Where-Object { $_.Enabled -eq 'True' }).Count -gt 0)
    $enabled = ($denyConnections -eq 0)

    [PSCustomObject]@{
        Supported       = (-not $isHomeEdition)
        Edition         = $caption
        Enabled         = [bool]$enabled
        NlaEnabled      = ($nla -eq 1)
        FirewallEnabled = [bool]$firewallEnabled
        Message         = if ($isHomeEdition) {
            'Windows Home cannot host Remote Desktop sessions.'
        }
        elseif ($enabled -and $firewallEnabled -and $nla -eq 1) {
            'Enabled with NLA and firewall rules.'
        }
        elseif ($enabled) {
            'Enabled, but firewall or NLA should be checked.'
        }
        else {
            'Disabled'
        }
    }
}

function Test-StickyAndFilterKeysDisabled {
    [CmdletBinding()]
    param()

    $sticky = ''
    $filter = ''

    try {
        $sticky = [string](Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Accessibility\StickyKeys' -Name 'Flags' -ErrorAction Stop).Flags
    }
    catch {
        $sticky = ''
    }

    try {
        $filter = [string](Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -ErrorAction Stop).Flags
    }
    catch {
        $filter = ''
    }

    $disabled = ($sticky -eq '506' -and $filter -eq '122')

    [PSCustomObject]@{
        Disabled = [bool]$disabled
        StickyFlags = $sticky
        FilterFlags = $filter
        Message = if ($disabled) { 'Disabled for current user.' } else { 'Shortcuts may still be enabled.' }
    }
}

function Get-VmDeploymentStatus {
    [CmdletBinding()]
    param()

    $environment = Get-VMEnvironment
    $vmwareInstaller = Find-VMwareToolsInstaller
    $virtualBoxInstaller = Find-VirtualBoxGuestAdditionsInstaller

    [PSCustomObject]@{
        Environment          = $environment
        VMwareTools          = Test-VMwareToolsInstalled
        VirtualBoxAdditions  = Test-VirtualBoxGuestAdditionsInstalled
        VMwareInstaller      = $vmwareInstaller
        VirtualBoxInstaller  = $virtualBoxInstaller
        RemoteDesktop        = Test-RemoteDesktopEnabled
        StickyAndFilterKeys  = Test-StickyAndFilterKeysDisabled
    }
}

function Invoke-VMwareToolsInstall {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock]$LogCallback
    )

    $installer = Find-VMwareToolsInstaller
    if ($null -eq $installer -or [string]::IsNullOrWhiteSpace($installer.Path)) {
        throw 'VMware Tools installer was not found. Mount the VMware Tools ISO from the hypervisor, then retry.'
    }

    Write-VmDeploymentLog -LogCallback $LogCallback -Level 'INSTALL' -Message "Installing VMware Tools from $($installer.Path)"
    $arguments = @('/S', '/v"/qn REBOOT=R"')
    $process = Start-Process -FilePath $installer.Path -ArgumentList $arguments -Wait -PassThru
    $exitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    $success = ($exitCode -in @(0, 3010, 1641) -or $null -eq $exitCode)
    $restartRequired = ($exitCode -in @(3010, 1641))

    $message = if ($success -and $restartRequired) {
        'VMware Tools installed. Restart required.'
    }
    elseif ($success) {
        'VMware Tools installation completed.'
    }
    else {
        "VMware Tools installer exited with code $exitCode."
    }

    Write-VmDeploymentLog -LogCallback $LogCallback -Level $(if ($success) { 'SUCCESS' } else { 'ERROR' }) -Message $message

    [PSCustomObject]@{
        Success         = [bool]$success
        ExitCode        = $exitCode
        RestartRequired = [bool]$restartRequired
        Message         = $message
    }
}

function Invoke-VirtualBoxGuestAdditionsInstall {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock]$LogCallback
    )

    $installer = Find-VirtualBoxGuestAdditionsInstaller
    if ($null -eq $installer -or [string]::IsNullOrWhiteSpace($installer.Path)) {
        throw 'VirtualBox Guest Additions installer was not found. Mount the Guest Additions ISO from VirtualBox, then retry.'
    }

    Write-VmDeploymentLog -LogCallback $LogCallback -Level 'INSTALL' -Message "Installing VirtualBox Guest Additions from $($installer.Path)"
    $process = Start-Process -FilePath $installer.Path -ArgumentList @('/S') -Wait -PassThru
    $exitCode = if ($null -ne $process) { $process.ExitCode } else { $null }
    $success = ($exitCode -in @(0, 3010, 1641) -or $null -eq $exitCode)
    $restartRequired = ($exitCode -in @(3010, 1641))

    $message = if ($success -and $restartRequired) {
        'VirtualBox Guest Additions installed. Restart required.'
    }
    elseif ($success) {
        'VirtualBox Guest Additions installation completed.'
    }
    else {
        "VirtualBox Guest Additions installer exited with code $exitCode."
    }

    Write-VmDeploymentLog -LogCallback $LogCallback -Level $(if ($success) { 'SUCCESS' } else { 'ERROR' }) -Message $message

    [PSCustomObject]@{
        Success         = [bool]$success
        ExitCode        = $exitCode
        RestartRequired = [bool]$restartRequired
        Message         = $message
    }
}

function Enable-RemoteDesktopAccess {
    [CmdletBinding()]
    param(
        [Parameter()]
        [scriptblock]$LogCallback
    )

    $status = Test-RemoteDesktopEnabled
    if (-not $status.Supported) {
        throw $status.Message
    }

    Write-VmDeploymentLog -LogCallback $LogCallback -Level 'INFO' -Message 'Enabling Remote Desktop with Network Level Authentication.'
    New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -PropertyType DWord -Value 1 -Force | Out-Null

    $rules = @()
    try {
        $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.Name -like 'RemoteDesktop-*' -or
            $_.DisplayGroup -eq 'Remote Desktop' -or
            $_.Group -eq '@FirewallAPI.dll,-28752'
        })
    }
    catch {
        Write-VmDeploymentLog -LogCallback $LogCallback -Level 'WARN' -Message "Unable to enumerate Remote Desktop firewall rules: $($_.Exception.Message)"
    }

    if ($rules.Count -gt 0) {
        $rules | Set-NetFirewallRule -Enabled True
        Write-VmDeploymentLog -LogCallback $LogCallback -Level 'INFO' -Message 'Remote Desktop firewall rules enabled.'
    }
    else {
        Write-VmDeploymentLog -LogCallback $LogCallback -Level 'WARN' -Message 'No Remote Desktop firewall rules were found.'
    }

    $termService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($null -ne $termService -and $termService.Status -ne 'Running') {
        Start-Service -Name 'TermService' -ErrorAction SilentlyContinue
    }

    $message = 'Remote Desktop enabled with NLA.'
    Write-VmDeploymentLog -LogCallback $LogCallback -Level 'SUCCESS' -Message $message

    [PSCustomObject]@{
        Success = $true
        Message = $message
    }
}

function Disable-StickyAndFilterKeysShortcuts {
    [CmdletBinding()]
    param(
        [Parameter()]
        [bool]$IncludeDefaultProfile = $true,

        [Parameter()]
        [scriptblock]$LogCallback
    )

    $targets = @(
        [PSCustomObject]@{
            Name = 'current user'
            Root = 'HKCU:\Control Panel\Accessibility'
            Required = $true
        }
    )

    if ($IncludeDefaultProfile) {
        $targets += [PSCustomObject]@{
            Name = 'logon/default user'
            Root = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Accessibility'
            Required = $false
        }
    }

    foreach ($target in $targets) {
        $stickyPath = Join-Path $target.Root 'StickyKeys'
        $filterPath = Join-Path $target.Root 'Keyboard Response'

        try {
            if (-not (Test-Path -LiteralPath $stickyPath)) {
                [void](New-Item -Path $stickyPath -Force)
            }
            if (-not (Test-Path -LiteralPath $filterPath)) {
                [void](New-Item -Path $filterPath -Force)
            }

            New-ItemProperty -LiteralPath $stickyPath -Name 'Flags' -PropertyType String -Value '506' -Force | Out-Null
            New-ItemProperty -LiteralPath $filterPath -Name 'Flags' -PropertyType String -Value '122' -Force | Out-Null
            Write-VmDeploymentLog -LogCallback $LogCallback -Level 'INFO' -Message "Sticky/Filter Keys shortcuts disabled for $($target.Name)."
        }
        catch {
            $message = "Unable to update Sticky/Filter Keys settings for $($target.Name): $($_.Exception.Message)"
            if ($target.Required) {
                throw $message
            }
            Write-VmDeploymentLog -LogCallback $LogCallback -Level 'WARN' -Message $message
        }
    }

    $message = 'Sticky Keys and Filter Keys shortcuts disabled.'
    Write-VmDeploymentLog -LogCallback $LogCallback -Level 'SUCCESS' -Message $message

    [PSCustomObject]@{
        Success = $true
        Message = $message
    }
}
