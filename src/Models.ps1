function Test-WingetPackageId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PackageId
    )

    $PackageId -match '^[A-Za-z0-9][A-Za-z0-9._+\-]*$'
}

function Test-AppAccentColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Color
    )

    $Color -match '^#[0-9A-Fa-f]{6}$'
}

function New-AppAccentBrush {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Color
    )

    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
        $mediaColor = [Windows.Media.ColorConverter]::ConvertFromString($Color)
        $brush = New-Object Windows.Media.SolidColorBrush -ArgumentList $mediaColor
        $brush.Freeze()
        return $brush
    }
    catch {
        return $Color
    }
}

function Resolve-AppLogoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CatalogPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$LogoPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogoPath)) {
        return ''
    }

    $candidate = if ([System.IO.Path]::IsPathRooted($LogoPath)) {
        $LogoPath
    }
    else {
        Join-Path (Split-Path -Parent $CatalogPath) $LogoPath
    }

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    ''
}

function New-AppLogoSource {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$LogoPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogoPath)) {
        return $null
    }

    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
        $uri = New-Object System.Uri -ArgumentList $LogoPath, ([System.UriKind]::Absolute)
        $image = New-Object Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.UriSource = $uri
        $image.EndInit()
        $image.Freeze()
        return $image
    }
    catch {
        return $null
    }
}

function New-AppLogoBrush {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$LogoSource
    )

    if ($null -eq $LogoSource) {
        return $null
    }

    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
        $brush = New-Object Windows.Media.ImageBrush
        $brush.ImageSource = $LogoSource
        $brush.Stretch = [Windows.Media.Stretch]::Uniform
        $brush.AlignmentX = [Windows.Media.AlignmentX]::Center
        $brush.AlignmentY = [Windows.Media.AlignmentY]::Center
        $brush.Freeze()
        return $brush
    }
    catch {
        return $null
    }
}

function New-AppLogoUri {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$LogoPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogoPath)) {
        return ''
    }

    try {
        $uri = New-Object System.Uri -ArgumentList $LogoPath, ([System.UriKind]::Absolute)
        return $uri.AbsoluteUri
    }
    catch {
        return ''
    }
}

function Get-AppLogoTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CatalogPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfiguredLogoPath = ''
    )

    $catalogRoot = Split-Path -Parent $CatalogPath

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredLogoPath)) {
        if ([System.IO.Path]::IsPathRooted($ConfiguredLogoPath)) {
            return $ConfiguredLogoPath
        }

        return (Join-Path $catalogRoot $ConfiguredLogoPath)
    }

    Join-Path (Join-Path $catalogRoot 'assets\logos') (ConvertTo-AppLogoFileName -Value $PackageId)
}

function Save-AppExternalLogoAsset {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Url = '',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    try {
        $uri = New-Object System.Uri -ArgumentList $Url
        if ($uri.Scheme -notin @('http', 'https')) {
            return ''
        }

        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $directory = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $tempPath = Join-Path ([IO.Path]::GetTempPath()) ('wsm-logo-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))

        try {
            Invoke-WebRequest `
                -Uri $uri.AbsoluteUri `
                -OutFile $tempPath `
                -UseBasicParsing `
                -TimeoutSec 20 `
                -Headers @{ 'User-Agent' = 'Windows Setup Manager' } `
                -ErrorAction Stop

            $image = $null
            try {
                $image = [Drawing.Image]::FromFile($tempPath)
                if ($image.Width -lt 8 -or $image.Height -lt 8) {
                    return ''
                }
            }
            finally {
                if ($null -ne $image) {
                    $image.Dispose()
                }
            }

            Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force
            return (Resolve-Path -LiteralPath $OutputPath).Path
        }
        finally {
            $ProgressPreference = $previousProgressPreference
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        return ''
    }
}

function ConvertTo-AppLogoFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    '{0}.png' -f (($Value -replace '[^A-Za-z0-9._-]', '_').ToLowerInvariant())
}

function ConvertFrom-AppHexColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')]
        [string]$Color
    )

    [Drawing.Color]::FromArgb(
        [Convert]::ToInt32($Color.Substring(1, 2), 16),
        [Convert]::ToInt32($Color.Substring(3, 2), 16),
        [Convert]::ToInt32($Color.Substring(5, 2), 16)
    )
}

function Get-AppLogoTextColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Drawing.Color]$Background
    )

    $luminance = ((0.299 * $Background.R) + (0.587 * $Background.G) + (0.114 * $Background.B))
    if ($luminance -gt 165) {
        return [Drawing.Color]::FromArgb(18, 21, 26)
    }

    [Drawing.Color]::White
}

function New-AppRoundedRectanglePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Drawing.RectangleF]$Rectangle,

        [Parameter(Mandatory)]
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $path
}

function New-AppLogoAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [Parameter(Mandatory)]
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')]
        [string]$AccentColor,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath
    )

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $directory = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $size = 128
        $accent = ConvertFrom-AppHexColor -Color $AccentColor
        $foreground = Get-AppLogoTextColor -Background $accent
        $bitmap = New-Object Drawing.Bitmap $size, $size
        $graphics = [Drawing.Graphics]::FromImage($bitmap)

        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $graphics.Clear([Drawing.Color]::Transparent)

            $bounds = New-Object Drawing.RectangleF 6, 6, 116, 116
            $path = New-AppRoundedRectanglePath -Rectangle $bounds -Radius 24
            $backgroundBrush = New-Object Drawing.SolidBrush $accent
            $graphics.FillPath($backgroundBrush, $path)

            $shine = New-Object Drawing.Drawing2D.LinearGradientBrush `
                ($bounds),
                ([Drawing.Color]::FromArgb(55, 255, 255, 255)),
                ([Drawing.Color]::FromArgb(0, 255, 255, 255)),
                90
            $graphics.FillPath($shine, $path)

            $borderPen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(70, 255, 255, 255)), 2
            $graphics.DrawPath($borderPen, $path)

            $cleanText = $Text.Trim()
            if ($cleanText.Length -gt 4) {
                $cleanText = $cleanText.Substring(0, 4)
            }

            $fontSize = switch ($cleanText.Length) {
                1 { 58 }
                2 { 50 }
                3 { 43 }
                default { 34 }
            }

            $font = New-Object Drawing.Font 'Segoe UI', $fontSize, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
            $format = New-Object Drawing.StringFormat
            $format.Alignment = [Drawing.StringAlignment]::Center
            $format.LineAlignment = [Drawing.StringAlignment]::Center
            $textBrush = New-Object Drawing.SolidBrush $foreground
            $textBounds = New-Object Drawing.RectangleF 8, 8, 112, 112
            $graphics.DrawString($cleanText, $font, $textBrush, $textBounds, $format)
            $bitmap.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
            return (Resolve-Path -LiteralPath $OutputPath).Path
        }
        finally {
            foreach ($resource in @($textBrush, $format, $font, $borderPen, $shine, $backgroundBrush, $path, $graphics, $bitmap)) {
                if ($null -ne $resource -and $resource -is [IDisposable]) {
                    $resource.Dispose()
                }
            }
        }
    }
    catch {
        return ''
    }
}

function Ensure-AppLogoAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CatalogPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogoText,

        [Parameter(Mandatory)]
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')]
        [string]$AccentColor,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfiguredLogoPath = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$LogoUrl = ''
    )

    $configuredPath = Resolve-AppLogoPath -CatalogPath $CatalogPath -LogoPath $ConfiguredLogoPath
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        return $configuredPath
    }

    $generatedPath = Get-AppLogoTargetPath -CatalogPath $CatalogPath -PackageId $PackageId -ConfiguredLogoPath $ConfiguredLogoPath

    if (Test-Path -LiteralPath $generatedPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $generatedPath).Path
    }

    $downloadedPath = Save-AppExternalLogoAsset -Url $LogoUrl -OutputPath $generatedPath
    if (-not [string]::IsNullOrWhiteSpace($downloadedPath)) {
        return $downloadedPath
    }

    New-AppLogoAsset -Text $LogoText -AccentColor $AccentColor -OutputPath $generatedPath
}

function Get-DefaultAppAccentColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Category
    )

    switch ($Category) {
        'Development' { '#4DA3FF' }
        'Dependencies' { '#5ED39D' }
        'Network' { '#7CC7FF' }
        'Multimedia' { '#FF7AB6' }
        'Utilities' { '#F2C94C' }
        'Office' { '#B6E37C' }
        'Security' { '#FF8A65' }
        'Gaming' { '#B388FF' }
        default { '#8DA2FB' }
    }
}

function Get-DefaultAppLogoText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    $matches = [regex]::Matches($Name, '[A-Za-z0-9+#]+')
    if ($matches.Count -eq 0) {
        return '?'
    }

    if ($matches.Count -eq 1) {
        $value = $matches[0].Value
        if ($value.Length -le 3) {
            return $value.ToUpperInvariant()
        }

        return $value.Substring(0, [Math]::Min(2, $value.Length)).ToUpperInvariant()
    }

    $letters = foreach ($match in $matches) {
        $match.Value.Substring(0, 1).ToUpperInvariant()
    }

    -join @($letters | Select-Object -First 3)
}

function Get-DefaultCategoryOrder {
    [CmdletBinding()]
    param()

    @(
        'All applications',
        'Development',
        'Dependencies',
        'Network',
        'Multimedia',
        'Utilities',
        'Office',
        'Security',
        'Gaming'
    )
}

function Import-AppCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "The apps.json file was not found: $Path"
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $items = $json | ConvertFrom-Json
    }
    catch {
        throw "The apps.json file is invalid: $($_.Exception.Message)"
    }

    if ($null -eq $items) {
        throw 'The apps.json file does not contain any applications.'
    }

    $requiredProperties = @('name', 'id', 'category', 'description', 'recommended', 'requiresAdmin')
    $models = New-Object System.Collections.Generic.List[object]
    $index = 0

    foreach ($item in @($items)) {
        $index++
        $propertyNames = @($item.PSObject.Properties.Name)

        foreach ($property in $requiredProperties) {
            if ($propertyNames -notcontains $property -or $null -eq $item.$property) {
                throw "apps.json: entry $index is missing required property '$property'."
            }
        }

        if (-not (Test-WingetPackageId -PackageId ([string]$item.id))) {
            throw "apps.json: WinGet ID '$($item.id)' is invalid."
        }

        $verifyCommand = ''
        if ($propertyNames -contains 'verifyCommand' -and $null -ne $item.verifyCommand) {
            $verifyCommand = [string]$item.verifyCommand
        }

        $logoText = if ($propertyNames -contains 'logoText' -and -not [string]::IsNullOrWhiteSpace([string]$item.logoText)) {
            [string]$item.logoText
        }
        else {
            Get-DefaultAppLogoText -Name ([string]$item.name)
        }

        $logoText = $logoText.Trim()
        if ($logoText.Length -gt 4) {
            $logoText = $logoText.Substring(0, 4)
        }

        $accentColor = if ($propertyNames -contains 'accentColor' -and -not [string]::IsNullOrWhiteSpace([string]$item.accentColor)) {
            [string]$item.accentColor
        }
        else {
            Get-DefaultAppAccentColor -Category ([string]$item.category)
        }

        if (-not (Test-AppAccentColor -Color $accentColor)) {
            throw "apps.json: color '$accentColor' for '$($item.name)' must use the #RRGGBB format."
        }

        $configuredLogoPath = if ($propertyNames -contains 'logoPath' -and $null -ne $item.logoPath) {
            [string]$item.logoPath
        }
        else {
            ''
        }

        $logoUrl = if ($propertyNames -contains 'logoUrl' -and $null -ne $item.logoUrl) {
            [string]$item.logoUrl
        }
        else {
            ''
        }

        $logoPath = Ensure-AppLogoAsset `
            -CatalogPath $Path `
            -PackageId ([string]$item.id) `
            -LogoText $logoText `
            -AccentColor $accentColor `
            -ConfiguredLogoPath $configuredLogoPath `
            -LogoUrl $logoUrl

        $logoSource = New-AppLogoSource -LogoPath $logoPath
        $logoBrush = New-AppLogoBrush -LogoSource $logoSource
        $logoUri = New-AppLogoUri -LogoPath $logoPath
        $accentBrush = New-AppAccentBrush -Color $accentColor

        [void]$models.Add([PSCustomObject]@{
            Name          = [string]$item.name
            Id            = [string]$item.id
            Category      = [string]$item.category
            Description   = [string]$item.description
            LogoText      = $logoText
            AccentColor   = $accentColor
            AccentBrush   = $accentBrush
            LogoDisplayBrush = if ($null -ne $logoBrush) { $logoBrush } else { $accentBrush }
            LogoPath      = $logoPath
            LogoUrl       = $logoUrl
            LogoUri       = $logoUri
            LogoSource    = $logoSource
            LogoImageVisibility = if (-not [string]::IsNullOrWhiteSpace($logoUri)) { 'Visible' } else { 'Collapsed' }
            LogoBadgeVisibility = if (-not [string]::IsNullOrWhiteSpace($logoUri)) { 'Collapsed' } else { 'Visible' }
            Recommended   = [bool]$item.recommended
            RequiresAdmin = [bool]$item.requiresAdmin
            VerifyCommand = $verifyCommand
            IsSelected    = [bool]$item.recommended
            IsInstalled   = $false
            Status        = 'Not checked'
            StatusKind    = 'Pending'
            LastMessage   = ''
        })
    }

    @($models.ToArray())
}

function Get-AppCategories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Apps
    )

    $defaultOrder = Get-DefaultCategoryOrder
    $existing = @($Apps | ForEach-Object { $_.Category } | Sort-Object -Unique)
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($category in $defaultOrder) {
        if ($category -eq 'All applications' -or $existing -contains $category) {
            [void]$result.Add($category)
        }
    }

    foreach ($category in $existing) {
        if ($result -notcontains $category) {
            [void]$result.Add($category)
        }
    }

    @($result.ToArray())
}

function Select-AppProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Apps,

        [Parameter(Mandatory)]
        [ValidateSet('All', 'None', 'Recommended')]
        [string]$Profile,

        [Parameter()]
        [bool]$IncludeInstalled = $false
    )

    foreach ($app in $Apps) {
        switch ($Profile) {
            'All' {
                $app.IsSelected = ($IncludeInstalled -or -not $app.IsInstalled)
            }
            'None' {
                $app.IsSelected = $false
            }
            'Recommended' {
                $app.IsSelected = ($app.Recommended -and ($IncludeInstalled -or -not $app.IsInstalled))
            }
        }
    }
}

function Get-SelectedApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Apps
    )

    @($Apps | Where-Object { $_.IsSelected })
}
